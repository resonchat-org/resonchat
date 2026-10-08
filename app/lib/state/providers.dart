// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:moxxmpp/moxxmpp.dart' show JID;

import '../account/account_hub.dart';
import '../account/resolve.dart';
import '../omemo/dual_track_manager.dart';
import '../omemo/protocol.dart';
import '../omemo/track.dart';
import '../store/database.dart';
import '../xmpp/avatar.dart';
import '../xmpp/blocking.dart';
import '../xmpp/muc.dart';
import '../xmpp/reactions.dart';
import '../ui/appearance.dart';
import '../xmpp/b_track_manager.dart';
import '../xmpp/capabilities.dart';
import '../xmpp/connection.dart';

/// Multi-account hub (installed in `main()`).
///
/// Rebuilds dependents when [AccountHub] notifies (session open/close), so
/// [databaseProvider] / [xmppServiceProvider] are not stuck on a cold-start
/// "no session" error after the first login.
final accountHubProvider = Provider<AccountHub>((ref) {
  final hub = accountHub;
  void onChange() => ref.invalidateSelf();
  hub.addListener(onChange);
  ref.onDispose(() => hub.removeListener(onChange));
  return hub;
});

/// Primary account DB (settings / SOCKS). Chat-scoped code must use
/// [dbForChatKey] / session lookup instead.
final databaseProvider = Provider<AppDatabase>((ref) {
  ref.watch(accountHubProvider);
  final db = accountHub.primaryDbOrNull;
  if (db == null) {
    throw StateError('databaseProvider: no account session');
  }
  return db;
});

final capabilityServiceProvider = Provider<CapabilityService>((ref) {
  final service = CapabilityService(
    tracks: () => ref.read(dualTrackManagerProvider)!,
    ourDeviceId: () async => ref.read(xmppServiceProvider).omemo?.getDeviceId(),
    ourPqDevices: () async {
      final b = ref.read(xmppServiceProvider).bTrack;
      final id = b?.device?.id;
      return (b?.ready ?? false) && id != null ? {id} : const <int>{};
    },
  );
  return service;
});

/// Dual-track managers for the primary session.
final Provider<DualTrackManager?> dualTrackManagerProvider =
    Provider<DualTrackManager?>((ref) {
      final xmpp = ref.watch(xmppServiceProvider);
      final moxxOmemo = xmpp.moxxOmemo;
      final pubsub = xmpp.pubsub;
      if (moxxOmemo == null || pubsub == null) return null;
      final tracks = DualTrackManager(
        aTrack: moxxOmemo,
        pubsubOf: () => pubsub,
      );
      xmpp.tracks = tracks;
      return tracks;
    });

/// Primary account's [XmppService] (settings, “open chat” when one account).
final Provider<XmppService> xmppServiceProvider = Provider<XmppService>((ref) {
  ref.watch(accountHubProvider);
  final xmpp = accountHub.primaryXmppOrNull;
  if (xmpp == null) {
    throw StateError('xmppServiceProvider: no account session');
  }
  return xmpp;
});

final Provider<BTrackManager> bTrackManagerProvider = Provider<BTrackManager>(
  (ref) => BTrackManager(
    tracks: () => ref.read(dualTrackManagerProvider)!,
    pubsubOf: () => ref.read(xmppServiceProvider).pubsub,
  ),
);

final connectionStateProvider = StateProvider<XmppConnectionState>(
  (ref) => XmppConnectionState.disconnected,
);

/// Whether the account's server advertises XEP-0363 HTTP File Upload.
///
/// Re-checked when the connection state changes; false while disconnected.
final httpUploadAvailableProvider = FutureProvider<bool>((ref) async {
  ref.watch(connectionStateProvider);
  final xmpp = ref.watch(xmppServiceProvider);
  if (xmpp.state != XmppConnectionState.connected) return false;
  return xmpp.httpFiles.isAvailable();
});

/// Live message list for one chat ([ChatRef.key] or legacy bare JID).
final messagesProvider = StreamProvider.family<List<Message>, String>((
  ref,
  chatKey,
) {
  final r = resolveChatKey(chatKey);
  return r.session.db.watchMessages(r.jid);
});

/// Unified multi-account chat list.
final chatsProvider = StreamProvider<List<AccountChat>>((ref) {
  ref.watch(accountHubProvider);
  return accountHub.watchMergedChats();
});

/// One chat row, or null while loading / unknown ([ChatRef.key]).
final chatProvider = FutureProvider.family<Chat?, String>((ref, chatKey) {
  final r = resolveChatKey(chatKey);
  return r.session.db.watchChats().first.then(
    (all) => all.where((c) => c.jid == r.jid).firstOrNull,
  );
});

final lastMessageProvider = StreamProvider.family<String?, String>((
  ref,
  chatKey,
) {
  final r = resolveChatKey(chatKey);
  return r.session.db.watchLastMessage(r.jid);
});

/// Live capability snapshot for a chat, or null while resolving.
///
/// The encryption info page shows this so the user can see exactly which
/// devices are counted as recipients.
/// Subscription state of one contact, and whether it is mutual.
///
/// Delivery is not just crypto: servers commonly refuse stanzas that are not
/// inside a mutual subscription, so the UI has to be able to say so instead
/// of leaving the user wondering why nothing arrives.
final contactStateProvider = FutureProvider.family<ContactState, String>((
  ref,
  chatKey,
) async {
  ref.watch(connectionStateProvider);
  final r = resolveChatKey(chatKey);
  final row = await r.session.db.rosterEntry(r.jid);
  return ContactState(
    subscription: row?.subscription ?? 'none',
    asked: (row?.ask ?? '').isNotEmpty,
  );
});

/// The subset of RFC 6121 subscription state the UI acts on.
class ContactState {
  const ContactState({required this.subscription, required this.asked});

  /// `none`, `to`, `from` or `both`.
  final String subscription;

  /// True when we have asked them and are waiting.
  final bool asked;

  bool get isMutual => subscription == 'both';

  /// One-line description for the user.
  String get summary => switch (subscription) {
    'both' => 'mutual',
    'to' =>
      asked
          ? 'they can see you; your request is pending'
          : 'they can see you; you cannot see them',
    'from' =>
      asked
          ? 'you can see them; your request is pending'
          : 'you can see them; they cannot see you',
    _ => 'not a contact',
  };
}

final chatCapabilitiesProvider =
    FutureProvider.family<ChatCapabilities?, String>((ref, chatKey) async {
      ref.watch(connectionStateProvider);
      final r = resolveChatKey(chatKey);
      final xmpp = r.session.xmpp;
      if (xmpp.omemo == null) return null;
      final caps = await xmpp.capabilitiesFor(JID.fromString(r.jid));
      if (caps == null || !caps.reliable) return null;
      return caps;
    });

/// Encryption mode for a chat, or [EncMode.none] while resolving.
///
/// The track messages in [chatJid] go out on: the per-conversation override
/// if the user set one, otherwise the global default.
///
/// This is the *choice*, not a negotiated answer and not what the peer
/// supports. Keeping the three apart is the whole point — a value that blended
/// them would silently change what the user asked for whenever a capability
/// lookup came back different.
///
/// The default is [Track.standard]: it is the only track a third-party client
/// can read, and a fresh install that starts on plaintext would hand every new
/// conversation to anyone with access to the server.
final chatTrackProvider = FutureProvider.family<Track, String>((
  ref,
  chatKey,
) async {
  final global = ref.watch(globalTrackProvider.future);
  final r = resolveChatKey(chatKey);
  final override = await r.session.db.trackOverride(r.jid);
  return override ?? await global;
});

/// Full-text search across every conversation, newest first.
///
/// Null while the needle is empty, so a caller can tell "no search running"
/// from "a search that found nothing" — a blank results list and an unopened
/// search must not look the same.
final messageSearchProvider = StreamProvider.autoDispose
    .family<List<Message>, String>((ref, needle) {
      if (needle.trim().isEmpty) return Stream.value(const []);
      ref.watch(accountHubProvider);
      final sessions = accountHub.sessions.toList();
      if (sessions.isEmpty) return Stream.value(const []);
      if (sessions.length == 1) {
        return sessions.first.db.searchMessages(needle);
      }
      // Merge per-account FTS streams (same bare JID on two accounts is rare).
      late final StreamController<List<Message>> controller;
      final subs = <StreamSubscription<List<Message>>>[];
      final latest = <int, List<Message>>{};
      void emit() {
        final all = latest.values.expand((e) => e).toList()
          ..sort((a, b) {
            final byTime = b.timestamp.compareTo(a.timestamp);
            if (byTime != 0) return byTime;
            return b.id.compareTo(a.id);
          });
        if (!controller.isClosed) {
          controller.add(all.length > 200 ? all.sublist(0, 200) : all);
        }
      }

      controller = StreamController<List<Message>>(
        onListen: () {
          for (var i = 0; i < sessions.length; i++) {
            final index = i;
            subs.add(
              sessions[i].db.searchMessages(needle).listen((list) {
                latest[index] = list;
                emit();
              }),
            );
          }
        },
        onCancel: () async {
          for (final s in subs) {
            await s.cancel();
          }
        },
      );
      return controller.stream;
    });

/// Search inside one conversation.
final chatMessageSearchProvider = StreamProvider.autoDispose
    .family<List<Message>, ({String chatJid, String needle})>((ref, args) {
      if (args.needle.trim().isEmpty) return Stream.value(const []);
      final r = resolveChatKey(args.chatJid);
      return r.session.db.searchInChat(r.jid, args.needle);
    });

/// One contact's avatar, fetched once and re-fetched only when its hash moves.
///
/// An [avatarRevision] is passed as `ref.watch`'s argument so an avatar push
/// invalidates every avatar at once without the caller having to know which
/// contacts changed.
final contactAvatarProvider = FutureProvider.family<Uint8List?, String>((
  ref,
  jid,
) async {
  ref.watch(avatarRevisionProvider);
  final xmpp = ref.watch(xmppServiceProvider);
  final manager = xmpp.avatarManager;
  if (manager == null) return null;
  final db = ref.watch(databaseProvider);

  final id = await latestAvatarId(manager, JID.fromString(jid).toBare());
  if (id == null) return null;
  // Same item id as last time means the bytes are the same, and the fetch is
  // the expensive part.
  if (await lastAvatarHash(db, jid) == id) {
    return _avatarBlobCache[jid];
  }
  final avatar = await fetchAvatar(
    manager,
    JID.fromString(jid).toBare(),
    id: id,
  );
  if (avatar == null) return null;
  await noteAvatarChanged(db, jid, id);
  _avatarBlobCache[jid] = avatar.bytes;
  return avatar.bytes;
});

/// Bumped when any contact republishes their avatar.
final avatarRevisionProvider = StateProvider<int>((ref) => 0);

/// Bytes already fetched this session, so a re-render never re-fetches.
final _avatarBlobCache = <String, Uint8List>{};

/// The room we are currently in, or null.
///
/// Keyed by [ChatRef.key] (or legacy bare JID) so multi-account sessions use
/// the owning [XmppService], not only the primary account.
final roomStateProvider = FutureProvider.family<GroupChat?, String>((
  ref,
  chatKey,
) async {
  // Re-reads when the occupant stream fires, so a new arrival shows up without
  // anything having to invalidate this.
  ref.watch(roomOccupantsProvider(chatKey));
  final r = resolveChatKey(chatKey);
  final roomJid = r.jid;
  final xmpp = r.session.xmpp;
  final state = await xmpp.groupChatState(roomJid);
  if (state == null) return null;
  // Conversations getUsers vs getOnlineUsers — private non-anon includes
  // offline affiliation members.
  final occupants = await xmpp.roomDisplayMembers(roomJid);
  return GroupChat(
    roomJid: roomJid,
    nick: state.nick ?? '',
    occupants: occupants,
    joined: state.joined,
  );
});

/// Occupants of the room for [chatKey], updated as presence arrives.
final roomOccupantsProvider = StreamProvider.family<List<Occupant>, String>((
  ref,
  chatKey,
) {
  final r = resolveChatKey(chatKey);
  return r.session.xmpp
      .roomOccupants(r.jid)
      .map((chat) => chat?.occupants ?? const []);
});

/// Archived conversations across accounts.
final archivedChatsProvider = StreamProvider<List<AccountChat>>((ref) {
  ref.watch(accountHubProvider);
  return accountHub.watchMergedChats(archivedOnly: true);
});

/// How [chatJid] looks: wallpaper, bubble shape, accent.
final chatAppearanceProvider = FutureProvider.family<ChatAppearance, String>((
  ref,
  chatKey,
) async {
  ref.watch(chatRowRevisionProvider);
  final r = resolveChatKey(chatKey);
  final chat = await r.session.db.watchChats().first;
  for (final c in chat) {
    if (c.jid == r.jid) return ChatAppearance.decode(c.appearance);
  }
  return const ChatAppearance();
});

/// Stores [appearance] for [chatKey], or clears it when null.
Future<void> setChatAppearance(
  WidgetRef ref,
  String chatKey,
  ChatAppearance? appearance,
) async {
  final r = resolveChatKey(chatKey);
  await r.session.db.setChatAppearance(r.jid, appearance?.encode());
  ref.read(chatRowRevisionProvider.notifier).state =
      ref.read(chatRowRevisionProvider) + 1;
}

/// Unread count for [chatKey], or null while it is being read.
final chatUnreadProvider = FutureProvider.family<int?, String>((
  ref,
  chatKey,
) async {
  ref.watch(chatRowRevisionProvider);
  final r = resolveChatKey(chatKey);
  final chat = await r.session.db.watchChats().first;
  for (final c in chat) {
    if (c.jid == r.jid) return c.unreadCount;
  }
  return null;
});

/// When the user last read [chatJid], or null before they ever have.
///
/// Watched by the chat page to place the unread boundary. Re-reads whenever the
/// row changes, so reading on another device moves the divider without a
/// restart.
final chatLastReadProvider = FutureProvider.family<DateTime?, String>((
  ref,
  chatKey,
) async {
  ref.watch(chatRowRevisionProvider);
  final r = resolveChatKey(chatKey);
  final chat = await r.session.db.watchChats().first;
  for (final c in chat) {
    if (c.jid == r.jid) return c.lastReadAt;
  }
  return null;
});

/// Bumped whenever a conversation row changes, so anything derived from it
/// (the unread badge, the read marker) re-reads.
final chatRowRevisionProvider = StateProvider<int>((ref) => 0);

/// Pending contact requests, newest first.
final subscriptionRequestsProvider = StreamProvider<List<SubscriptionRequest>>(
  (ref) => ref.watch(databaseProvider).watchSubscriptionRequests(),
);

/// The unsent text in [chatKey], or null.
final draftProvider = FutureProvider.family<String?, String>((ref, chatKey) {
  ref.watch(draftRevisionProvider);
  final r = resolveChatKey(chatKey);
  return r.session.db.draft(r.jid);
});

/// Bumped whenever a draft changes, so the input bar redraws.
final draftRevisionProvider = StateProvider<int>((ref) => 0);

/// Records or clears the draft for [chatKey].
Future<void> saveDraft(WidgetRef ref, String chatKey, String? text) async {
  final r = resolveChatKey(chatKey);
  await r.session.db.setDraft(r.jid, text);
  ref.read(draftRevisionProvider.notifier).state =
      ref.read(draftRevisionProvider) + 1;
}

/// Stanza ids pinned in [chatKey], most recent first.
final pinnedIdsProvider = StreamProvider.family<List<String>, String>((
  ref,
  chatKey,
) {
  final r = resolveChatKey(chatKey);
  return r.session.db.watchPinned(r.jid);
});

/// Pins or unpins a message.
Future<void> togglePinned(
  WidgetRef ref,
  String chatKey,
  String stanzaId,
) async {
  final r = resolveChatKey(chatKey);
  await r.session.db.togglePinned(r.jid, stanzaId);
}

/// The bare JIDs currently blocked (XEP-0191).
///
/// Read from the store rather than from the service's in-memory copy: this is
/// what the UI draws, and the store is the thing that survives a restart.
final blockedJidsProvider = FutureProvider<Set<String>>((ref) async {
  // Invalidated by every block and unblock, so the tiles redraw.
  ref.watch(blockRevisionProvider);
  return ref.watch(databaseProvider).blockedJids();
});

/// Bumped whenever the block list changes.
final blockRevisionProvider = StateProvider<int>((ref) => 0);

/// True when the peer for [chatKey] (or bare JID) is blocked on that account.
final isBlockedProvider = Provider.family<bool, String>((ref, chatKey) {
  ref.watch(blockRevisionProvider);
  final r = resolveChatKey(chatKey);
  return r.session.xmpp.blockedJids.contains(r.jid);
});

/// Blocks or unblocks the peer for [chatKey], on the owning session.
Future<void> toggleBlocked(
  WidgetRef ref,
  String chatKey, {
  required bool currentlyBlocked,
}) async {
  final r = resolveChatKey(chatKey);
  final db = r.session.db;
  final xmpp = r.session.xmpp;
  final jid = r.jid;
  if (currentlyBlocked) {
    await unblockContact(xmpp, db, jid);
  } else {
    await blockContact(xmpp, db, jid);
  }
  // Both writes happened; re-read rather than guessing, because a server push
  // can arrive in between and the tile has to show what is actually enforced.
  xmpp.blockedJids = await db.blockedJids();
  ref.read(blockRevisionProvider.notifier).state =
      ref.read(blockRevisionProvider) + 1;
}

/// Reaction chips for one message in one chat.
///
/// Keyed on chat + stanza id so multi-account DBs do not mix chips, and so
/// "mine" is judged against the owning account's bare JID.
final reactionGroupsProvider =
    FutureProvider.family<
      List<ReactionGroup>,
      ({String chatKey, String targetId})
    >((ref, args) async {
      ref.watch(reactionRevisionProvider);
      final r = resolveChatKey(args.chatKey);
      final myJid = r.session.xmpp.myJid;
      if (myJid == null) return const [];
      return reactionsFor(r.session.db, args.targetId, myJid);
    });

/// Bumped whenever a reaction is stored, to invalidate every chip strip.
final reactionRevisionProvider = StateProvider<int>((ref) => 0);

/// Our own bare JID, or null before login.
final myBareJidProvider = FutureProvider<String?>((ref) async {
  final xmpp = ref.watch(xmppServiceProvider);
  return xmpp.myJid;
});

/// The override set for [chatJid], or null when there is none.
///
/// Separate from [chatTrackProvider] because "inherits the global default" and
/// "is set to the same value as the global default" are different states: only
/// the first one follows a later change to the default.
final chatTrackOverrideProvider = FutureProvider.family<Track?, String>((
  ref,
  chatKey,
) {
  final r = resolveChatKey(chatKey);
  return r.session.db.trackOverride(r.jid);
});

/// The track used by conversations with no override of their own.
final globalTrackProvider = FutureProvider<Track>((ref) async {
  final stored = await ref.read(databaseProvider).metaValue(_globalTrackKey);
  if (stored == null) return Track.standard;
  return Track.fromStored(stored) ?? Track.standard;
});

/// Stores the global default.
Future<void> setGlobalTrack(WidgetRef ref, Track track) async {
  await ref.read(databaseProvider).setMetaValue(_globalTrackKey, track.stored);
}

/// Pins [chatKey] to [track], or clears the override when null.
Future<void> setChatTrack(WidgetRef ref, String chatKey, Track? track) async {
  final r = resolveChatKey(chatKey);
  await r.session.db.setTrackOverride(r.jid, track);
  await r.session.db.clearPlaintextAcknowledgement(r.jid);
  ref.invalidate(chatTrackOverrideProvider(chatKey));
  ref.invalidate(chatTrackProvider(chatKey));
}

/// Database key holding the global default track.
const _globalTrackKey = 'global_track';
