// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:flutter/widgets.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import 'package:moxxmpp/moxxmpp.dart' show JID;

import 'package:resonchat/account/account_hub.dart';
import 'package:resonchat/account/chat_ref.dart';
import 'package:resonchat/crypto/dual/dual_track_manager.dart';
import 'package:resonchat/crypto/dual/track.dart';
import 'package:resonchat/crypto/dual/track_advice.dart';
import 'package:resonchat/persistence/database.dart';
import 'package:resonchat/platform/app_notifications.dart';
import 'package:resonchat/security/app_lock.dart';
import 'package:resonchat/state/providers.dart';
import 'package:resonchat/xmpp/auto_reply.dart';
import 'package:resonchat/xmpp/chat_notify_mode.dart';
import 'package:resonchat/xmpp/connection.dart';
import 'package:resonchat/xmpp/encryption/capabilities.dart';
import 'package:resonchat/xmpp/message_expiry.dart';
import 'package:resonchat/xmpp/notify_policy.dart';
import 'package:resonchat/xmpp/roster/blocking.dart';

/// Connects the connection's streams to persistent state for the app's
/// lifetime: delivery receipts, delivery failures and capability
/// invalidation.
///
/// All three used to be wired from whichever page happened to be mounted.
/// A delivery receipt that arrived while the user sat in a conversation was
/// therefore dropped, and the message stayed marked "not delivered" for
/// good. Doing it here means the bookkeeping follows the connection, not the
/// navigation stack.
///
/// The capability service deliberately lives in the widget layer rather than
/// in a provider.
///
/// This deliberately lives in the widget layer rather than in a provider.
/// Doing it in a provider created a cycle the moment the encryption page
/// asked for capabilities: `capabilityServiceProvider` resolves its managers
/// through `dualTrackManagerProvider`, and that provider depended on the
/// wiring provider, which depended on `capabilityServiceProvider` again.
/// Riverpod reported it as a `CircularDependencyError` — a red screen on a
/// real device, invisible to unit tests because they never build two
/// providers that reference each other through a lazy callback.
///
/// Keeping it in the tree also makes the lifetime obvious: the wiring is
/// attached while a widget is mounted and removed when it goes away.
class AppWiring extends ConsumerStatefulWidget {
  const AppWiring({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<AppWiring> createState() => _AppWiringState();
}

class _AppWiringState extends ConsumerState<AppWiring>
    with WidgetsBindingObserver {
  final List<StreamSubscription<Object?>> _subs = [];
  StreamSubscription<void>? _hubSub;
  final _messageExpiry = MessageExpiryRunner();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bindAll();
    _hubSub = accountHub.sessionChanges.listen((_) => _bindAll());
    _messageExpiry.start();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    ref.read(appForegroundProvider.notifier).state =
        state == AppLifecycleState.resumed;
    // Amarok ScreenStatusReceiver: re-lock when leaving the foreground.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      AppLock.instance.lockAndDisguise();
    }
    // Gajim `cleanup_chat_history` runs from `_shutdown_core`, including
    // max_age 0 ("Until Gajim is Closed"). Not on pause: backgrounding is
    // not closing the app.
    if (state == AppLifecycleState.detached) {
      unawaited(expireOldMessagesAcrossAccounts(atShutdown: true));
    }
  }

  void _bindAll() {
    for (final sub in _subs) {
      sub.cancel();
    }
    _subs.clear();
    for (final session in accountHub.sessions) {
      _wireSession(session);
    }
    _syncConnectionState();
    unawaited(_messageExpiry.runOnce());
  }

  /// Keep [connectionStateProvider] aligned with the primary session.
  ///
  /// Cold start never went through the login page, so this stayed
  /// `disconnected` even when XMPP was up — caps / upload / UI looked offline.
  ///
  /// Deferred: [_bindAll] runs from [initState], and Riverpod forbids
  /// provider writes during widget lifecycle.
  void _syncConnectionState() {
    final xmpp = accountHub.primaryXmppOrNull;
    if (xmpp == null) return;
    final next = xmpp.state;
    Future(() {
      if (!mounted) return;
      ref.read(connectionStateProvider.notifier).state = next;
    });
  }

  /// 1:1 markers name the peer's bare JID. A room marker's `from` is
  /// `room/nick`; only a private non-anonymous room records that nick's real
  /// JID, and only when the occupant list publishes one.
  Future<void> _noteReadReceipt(
    AccountSession session,
    ReadReceipt receipt,
  ) async {
    final bare = receipt.from.toBare().toString();
    final nick = receipt.from.resource;
    if (nick.isEmpty) {
      await session.db.markDisplayed(bare, receipt.stanzaId);
      return;
    }
    final chat = await session.db.getChat(bare);
    if (chat == null || !chat.isGroup || !chat.mucPrivateNonAnonymous) return;
    if (nick == chat.mucNick) return;
    final members = await session.xmpp.roomDisplayMembers(bare);
    String? real;
    for (final occupant in members) {
      final jid = occupant.realJid?.trim() ?? '';
      if (occupant.nick == nick && jid.isNotEmpty) {
        real = jid;
        break;
      }
    }
    if (real == null) return;
    final mine = session.xmpp.myJid;
    if (mine != null && real.toLowerCase() == mine.toLowerCase()) return;
    await session.db.noteGroupRead(
      chatJid: bare,
      markerId: receipt.stanzaId,
      readerJid: real,
    );
  }

  void _wireSession(AccountSession session) {
    final xmpp = session.xmpp;
    final db = session.db;
    final tracks = xmpp.tracks ?? session.tracks;
    if (tracks != null) {
      tracks.omemoDeviceMemory = PublishedDeviceMemory(
        load: () => db.publishedOmemoDeviceIds(),
        save: (ids) => db.savePublishedOmemoDeviceIds(ids),
      );
      tracks.pqDeviceMemory = PublishedDeviceMemory(
        load: () => db.publishedPqDeviceIds(),
        save: (ids) => db.savePublishedPqDeviceIds(ids),
      );
      // Per-session capability service — primary-only provider would resolve
      // secondary accounts against the wrong OMEMO / PQ device set.
      final caps = CapabilityService(
        tracks: () => tracks,
        ourDeviceId: () async => xmpp.omemo?.getDeviceId(),
        ourPqDevices: () async {
          final b = xmpp.bTrack;
          final id = b?.device?.id;
          return (b?.ready ?? false) && id != null ? {id} : const <int>{};
        },
      );
      xmpp.attachCapabilities(caps);
      _subs.add(
        xmpp.capabilityChanges.listen((jid) {
          caps.invalidate(jid);
          unawaited(_noticeCapabilityChange(ref, session, jid));
        }),
      );
    } else {
      _subs.add(
        xmpp.capabilityChanges.listen((jid) {
          unawaited(_noticeCapabilityChange(ref, session, jid));
        }),
      );
    }
    unawaited(_loadPrivacyPrefs(session));
    _subs.add(
      xmpp.deliveryReceipts.listen((receipt) {
        unawaited(
          db.markDelivered(receipt.from.toBare().toString(), receipt.stanzaId),
        );
      }),
    );
    _subs.add(
      xmpp.readReceipts.listen((receipt) {
        unawaited(_noteReadReceipt(session, receipt));
      }),
    );
    unawaited(_syncPendingRequests(session));
    for (final jid in xmpp.pendingOutgoingRequests) {
      unawaited(db.addOutgoingRequest(jid));
    }
    _subs.add(
      xmpp.outgoingRequests.listen((jid) async {
        await db.addOutgoingRequest(jid.toBare().toString());
      }),
    );
    _subs.add(
      xmpp.incomingRequests.listen((jid) async {
        await db.addIncomingRequest(jid.toBare().toString());
      }),
    );
    _subs.add(
      xmpp.roomInvites.listen((invite) async {
        await db.upsertRoomInvitation(
          roomJid: invite.roomJid,
          fromJid: invite.fromJid,
          password: invite.password,
          reason: invite.reason,
        );
      }),
    );
    unawaited(_loadBlocked(ref, session));
    _subs.add(
      xmpp.blocklistChanges.listen((pushed) async {
        if (pushed.isEmpty) {
          for (final jid in await db.blockedJids()) {
            await db.removeBlocked(jid);
          }
        } else {
          await applyBlockPush(db, pushed);
        }
        await _loadBlocked(ref, session);
      }),
    );
    _subs.add(
      xmpp.reactions.listen((msg) {
        final update = msg.reactions;
        if (update == null) return;
        unawaited(session.messages.storeReaction(update));
      }),
    );
    _subs.add(
      xmpp.inbound.listen(
        (msg) => unawaited(_acceptInbound(ref, session, msg)),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _messageExpiry.stop();
    _hubSub?.cancel();
    for (final sub in _subs) {
      sub.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Re-resolves one conversation after a PEP change and records any advice
/// worth showing (docs/10 §8).
///
/// Deliberately does **not** touch the stored track. A message's protocol
/// changing for the same contact without the user doing anything looks like a
/// bug, and they have no way to tell it apart from their choice being
/// overridden.
///
/// The previous snapshot is kept so only real transitions are reported. Without
/// it, every PEP notification would re-announce the same situation.
Future<void> _noticeCapabilityChange(
  WidgetRef ref,
  AccountSession session,
  JID jid,
) async {
  final bare = jid.toBare().toString();
  final cacheKey = '${session.account.id}\x1f$bare';
  final before = _lastCapabilities[cacheKey];
  try {
    final after = await session.xmpp.capabilitiesFor(jid);
    if (after == null) return;
    _lastCapabilities[cacheKey] = after;
    final chosen =
        await session.db.trackOverride(bare) ??
        await ref.read(globalTrackProvider.future);
    final track = chosen ?? Track.standard;
    final advice = compareCapabilities(
      chatJid: bare,
      chosen: track,
      previous: before ?? after,
      current: after,
    );
    if (advice != null) _advice.add(advice);
  } catch (e) {
    Logger('AppWiring').fine('capability re-resolve for $bare failed: $e');
  }
}

Future<void> _acceptInbound(
  WidgetRef ref,
  AccountSession session,
  InboundMessage msg,
) async {
  final db = session.db;
  final ownBare = session.xmpp.myJid;
  final mentionsMe = await session.messages.storeInbound(msg, ownBare: ownBare);
  final chatJid = _chatJidFor(msg, ownBare);
  if (_isOwnArchive(msg, ownBare)) return;
  if (msg.fromArchive) return;

  final chat = await db.getChat(chatJid);
  final isGroup = chat?.isGroup ?? msg.type == 'groupchat';
  final privateMessage =
      isGroup && msg.type == 'chat' && msg.from.resource.isNotEmpty;
  final openKey = ref.read(openChatKeyProvider);
  final chatKey = ChatRef(accountId: session.account.id, jid: chatJid).key;
  final reading = openKey == chatKey;
  final foreground = ref.read(appForegroundProvider);

  final exceptSender = await _senderStillNotifies(
    session: session,
    chat: chat,
    isGroup: isGroup,
    roomJid: chatJid,
    nick: msg.from.resource,
  );
  final policy = NotifyPolicy(
    sender: NotifyIdentity(
      jid: msg.from.toString(),
      nickname: isGroup && msg.from.resource.isNotEmpty
          ? msg.from.resource
          : null,
    ),
    me: NotifyIdentity(
      jid: ownBare ?? '',
      nickname: isGroup
          ? (chat?.mucNick.isNotEmpty == true ? chat!.mucNick : null)
          : null,
    ),
    body: msg.encryptionError != null ? '' : msg.body,
    muted: chat?.muted ?? false,
    alwaysNotify: isGroup ? (chat?.alwaysNotify ?? true) : true,
    exceptSender: exceptSender,
    archived: chat?.archived ?? false,
    pinned: chat?.pinned ?? false,
    isGroup: isGroup,
    carbon: msg.isCarbonCopy,
    undecryptable: msg.encryptionError != null,
    blocked: session.xmpp.blockedJids.contains(chatJid),
    appInForeground: foreground,
    reading: reading,
    privateMessage: privateMessage,
  );

  final decision = decide(policy);
  if (decision.countsAsUnread) {
    await db.markChatUnread(
      chatJid,
      arrivedAt: msg.archiveTimestamp ?? DateTime.now(),
      mentionsMe: mentionsMe || mentionsUser(policy),
    );
  }
  final request = notificationFor(policy, chatJid: chatJid);
  if (request != null) {
    final title = (chat?.title.isNotEmpty == true) ? chat!.title : chatJid;
    unawaited(
      AppNotifications.instance.post(
        accountId: session.account.id,
        chatJid: chatJid,
        title: title,
        request: request,
      ),
    );
  }
  unawaited(
    maybeSendAutoReply(
      session: session,
      msg: msg,
      chatJid: chatJid,
      isGroup: isGroup,
      ownBare: ownBare,
    ),
  );
}

/// True when [nick] is on this group's Still notify list.
Future<bool> _senderStillNotifies({
  required AccountSession session,
  required Chat? chat,
  required bool isGroup,
  required String roomJid,
  required String nick,
}) async {
  if (!isGroup || chat == null) return false;
  final mode = chatNotifyModeOf(
    muted: chat.muted,
    alwaysNotify: chat.alwaysNotify,
  );
  if (!mode.isSilenced) return false;
  final except = decodeNotifyExcept(chat.notifyExcept);
  if (except.isEmpty || nick.isEmpty) return false;
  String? realJid;
  final members = await session.xmpp.roomDisplayMembers(roomJid);
  for (final occupant in members) {
    if (occupant.nick == nick) {
      realJid = occupant.realJid;
      break;
    }
  }
  return senderIsNotifyExcept(except: except, nick: nick, realJid: realJid);
}

/// Conversation bare JID for [msg], accounting for our own archived outbound.
String _chatJidFor(InboundMessage msg, String? ownBare) {
  if (_isOwnArchive(msg, ownBare) && msg.to != null) {
    return msg.to!.toBare().toString();
  }
  return msg.from.toBare().toString();
}

bool _isOwnArchive(InboundMessage msg, String? ownBare) {
  if (!msg.fromArchive || ownBare == null) return false;
  return msg.from.toBare().toString() == ownBare;
}

Future<void> _loadPrivacyPrefs(AccountSession session) async {
  final db = session.db;
  final xmpp = session.xmpp;
  xmpp.sendDeliveryReceipts = await db.sendDeliveryReceiptsEnabled();
  xmpp.sendReadReceipts = await db.sendReadReceiptsEnabled();
  xmpp.sendTypingNotifications = await db.sendChatStatesEnabled();
}

Future<void> _syncPendingRequests(AccountSession session) async {
  final db = session.db;
  final xmpp = session.xmpp;
  for (final jid in xmpp.pendingIncomingRequests) {
    await db.addIncomingRequest(jid);
  }
  for (final jid in xmpp.pendingOutgoingRequests) {
    await db.addOutgoingRequest(jid);
  }
}

Future<void> _loadBlocked(WidgetRef ref, AccountSession session) async {
  final jids = await session.db.blockedJids();
  session.xmpp.blockedJids = jids;
  try {
    ref.read(blockRevisionProvider.notifier).state++;
  } catch (_) {}
}

/// The last capability snapshot seen per conversation.
///
/// Held in memory on purpose: it answers "did something change since we last
/// looked", and persisting it would mean a snapshot from last week being
/// compared against today's as though it were current.
final _lastCapabilities = <String, ChatCapabilities>{};

/// Advice about conversations whose capabilities changed.
///
/// A stream rather than stored state: each piece is worth showing once, and a
/// stored banner would come back after a restart for something that may no
/// longer be true.
final _advice = StreamController<TrackAdvice>.broadcast();
Stream<TrackAdvice> get trackAdvice => _advice.stream;

/// Forgets the snapshot for [jid], so the next change is judged against
/// nothing rather than against a stale answer.
///
/// Called when the account changes: another account's devices are another
/// account's business.
void forgetCapabilityHistory() => _lastCapabilities.clear();
