// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:logging/logging.dart';
import 'package:moxxmpp/moxxmpp.dart' show JID;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';
import '../omemo/track.dart';
import '../omemo/track_advice.dart';
import '../store/database.dart';
import '../xmpp/capabilities.dart';
import '../xmpp/blocking.dart';
import '../xmpp/connection.dart';
import '../xmpp/reactions.dart';
import '../xmpp/retraction.dart';

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

class _AppWiringState extends ConsumerState<AppWiring> {
  final List<StreamSubscription<Object?>> _subs = [];

  @override
  void initState() {
    super.initState();
    final xmpp = ref.read(xmppServiceProvider);
    xmpp.attachCapabilities(ref.read(capabilityServiceProvider));
    // A PEP change must drop the cached answer, not wait out the TTL.
    _subs.add(xmpp.capabilityChanges.listen((jid) {
      ref.read(capabilityServiceProvider).invalidate(jid);
      // The cached answer is dropped, but the chat's own provider is not
      // refreshed here: doing it immediately would resolve the new
      // capabilities in the background of a PEP notification nobody asked
      // for, and — worse — let a transient bundle-fetch failure arrive as if
      // it were a real change. The advice below re-resolves and compares,
      // which is the only place a change should be interpreted.
      unawaited(_noticeCapabilityChange(ref, jid));
    }));
    // XEP-0184: flip our outgoing messages to "delivered".
    _subs.add(xmpp.deliveryReceipts.listen((receipt) {
      unawaited(
        ref.read(databaseProvider).markDelivered(
              receipt.from.toBare().toString(),
              receipt.stanzaId,
            ),
      );
    }));
    // Subscription requests are recorded rather than approved. The list lives
    // in the store so it survives the process being killed between the request
    // arriving and the user opening the app to look at it.
    // Requests the server had already sent before this listener existed, and
    // any it re-sends after a reconnect. Synced once at startup so the list is
    // the truth rather than "whatever arrived while we happened to be
    // listening".
    unawaited(_syncPendingRequests(ref));
    for (final jid in xmpp.pendingOutgoingRequests) {
      unawaited(ref.read(databaseProvider).addOutgoingRequest(jid));
    }

    _subs.add(xmpp.outgoingRequests.listen((jid) async {
      await ref
          .read(databaseProvider)
          .addOutgoingRequest(jid.toBare().toString());
    }));

    _subs.add(xmpp.incomingRequests.listen((jid) async {
      final db = ref.read(databaseProvider);
      await db.addIncomingRequest(jid.toBare().toString());
    }));

    // XEP-0191: the blocked list lives on the server so another of our
    // devices enforcing it also takes effect here. Loaded once at startup and
    // pushed whenever the server sends a change.
    unawaited(_loadBlocked(ref));
    _subs.add(xmpp.blocklistChanges.listen((pushed) async {
      final db = ref.read(databaseProvider);
      if (pushed.isEmpty) {
        // An empty push means "unblock everything" (XEP-0191). Distinguishing
        // that from "no change" matters: treating it as no-change would leave
        // this device enforcing blocks the user lifted elsewhere.
        for (final jid in await db.blockedJids()) {
          await db.removeBlocked(jid);
        }
      } else {
        await applyBlockPush(db, pushed);
      }
      await _loadBlocked(ref);
    }));

    // XEP-0444: reactions are stored, never inserted as messages. A reaction
    // arrives in its own stanza; storing it would put an empty bubble above
    // the message it belongs to.
    _subs.add(xmpp.reactions.listen((msg) {
      final update = msg.reactions;
      if (update == null) return;
      unawaited(storeReaction(ref.read(databaseProvider), update));
    }));

    // Persist inbound traffic. This used to live in the chat list, so a
    // message that arrived while the user was somewhere else in the app
    // was never written down — a silent data loss that only showed up as a
    // conversation that looked empty when reopened.
    _subs.add(
      xmpp.inbound.listen(
        (msg) => unawaited(_acceptInbound(ref, msg)),
      ),
    );
  }

  @override
  void dispose() {
    for (final sub in _subs) {
      sub.cancel();
    }
    // The advice stream outlives this widget on purpose: the chat page
    // subscribes to it, and tearing it down here would close the stream under
    // a listener that is still mounted.
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
Future<void> _noticeCapabilityChange(WidgetRef ref, JID jid) async {
  final bare = jid.toBare().toString();
  final service = ref.read(capabilityServiceProvider);
  final before = _lastCapabilities[bare];
  try {
    final after = await service.forChat(jid);
    _lastCapabilities[bare] = after;
    // globalTrackProvider never resolves to null; the override may be absent,
    // which is the case that falls through to the default.
    final chosen = await ref.read(databaseProvider).trackOverride(bare) ??
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
    // A failed re-resolve is not a change. Swallowing it here is what keeps
    // the stream alive and the conversation's cached answer absent, so the
    // next send refuses rather than guessing.
    Logger('AppWiring').fine('capability re-resolve for $bare failed: $e');
  }
}

/// Stores one inbound message and updates the conversation's unread state.
///
/// Unread is decided here rather than in the chat list, because the list is not
/// necessarily mounted: a message that arrives with no UI on screen has to be
/// counted somewhere, or opening the app later shows a conversation that looks
/// read when a message was sitting there the whole time.
Future<void> _acceptInbound(WidgetRef ref, InboundMessage msg) async {
  final db = ref.read(databaseProvider);
  await storeInbound(db, msg);
  final chatJid = msg.from.toBare().toString();
  // A carbon is a copy of one of our own messages. Counting it would show an
  // unread badge for something the user wrote.
  if (msg.isCarbonCopy) return;
  final chat = (await db.watchChats().first)
      .where((c) => c.jid == chatJid)
      .firstOrNull;
  // Muted conversations still receive and store; they just do not get a badge,
  // because muting is a promise that nothing will interrupt.
  if (chat?.muted ?? false) return;
  if (chat?.archived ?? false) return;
  // A blocked contact's message should not have reached here at all — the
  // inbound handler drops it before it is opened. Counting it defensively costs
  // one lookup and removes a whole class of "why is there a badge for someone I
  // blocked" reports.
  if (ref.read(xmppServiceProvider).blockedJids.contains(chatJid)) return;
  await db.markChatUnread(
    chatJid,
    arrivedAt: msg.archiveTimestamp ?? DateTime.now(),
  );
}

/// Copies the service's pending requests into the store.
///
/// Both directions, and done unconditionally: the point is that the store ends
/// up holding everything the service knows about, including anything that
/// arrived before this ran.
Future<void> _syncPendingRequests(WidgetRef ref) async {
  final db = ref.read(databaseProvider);
  final xmpp = ref.read(xmppServiceProvider);
  for (final jid in xmpp.pendingIncomingRequests) {
    await db.addIncomingRequest(jid);
  }
  for (final jid in xmpp.pendingOutgoingRequests) {
    await db.addOutgoingRequest(jid);
  }
}

/// Reads the block list from the store into the service's in-memory copy.
///
/// The service keeps the list because the inbound path is on the hot path for
/// every message, and the store is not. Keeping the two in step is this
/// function's whole job, which is why every writer goes through here.
Future<void> _loadBlocked(WidgetRef ref) async {
  final db = ref.read(databaseProvider);
  final jids = await db.blockedJids();
  ref.read(xmppServiceProvider).blockedJids = jids;
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

/// Writes one inbound message into the store.
///
/// Idempotent by stanza id, so a carbon that arrives twice, or a message
/// that is also replayed from the archive, cannot duplicate a bubble.
Future<void> storeInbound(AppDatabase db, InboundMessage msg) async {
  // In a room the sender is the *nick*, not the address. Storing the room as
  // the conversation and the nick as the sender is what makes `room@server`
  // and `room@server/nick` the same conversation in the chat list, and what
  // puts the right name on the bubble.
  final chatJid = msg.from.toBare().toString();
  final sender = msg.from.toString();
  await db.upsertChat(chatJid);

  // A carbon duplicates a message we already hold locally.
  if (msg.isCarbonCopy) return;
  final stanzaId = msg.stanzaId ?? '';
  if (await db.findByStanzaId(chatJid, stanzaId) != null) return;
  // A room message is identified by its sender's full JID, not just the room:
  // two people in the same room can, and frequently do, send stanzas with the
  // same id. Deduplicating on the bare room would drop the second one.
  final dedupeKey = sender.isEmpty ? stanzaId : sender;
  if (await db.findByStanzaId(chatJid, dedupeKey) != null) return;

  // A stanza carrying an apply-to is an instruction about an earlier message,
  // not a message. Storing it would put a duplicate bubble next to the one it
  // refers to, and for a retraction the bubble would contain the fallback text
  // as though the sender had written it.
  if (msg.retracts != null) {
    await applyRetraction(db, msg.retracts!);
    return;
  }
  if (msg.corrects != null) {
    // A correction is a new rendering of the original: the body is its real
    // content, encrypted like any other message, so the track comes from the
    // sender's declaration rather than from anything we chose.
    await correctMessage(
      db: db,
      chatJid: chatJid,
      targetId: msg.corrects!,
      body: msg.body,
      track: msg.track ?? Track.none,
    );
    return;
  }

  await db.insertMessage(
    MessagesCompanion(
      chatJid: Value(chatJid),
      sender: Value(sender),
      // The origin-id when the sender published one, because that is the id
      // reactions, replies, edits and retractions address. The server's stanza
      // id is a fallback and it changes across an archive round trip, so a
      // message keyed on it becomes unaddressable after a MAM import.
      stanzaId: Value(msg.originId ?? stanzaId),
      // The reply body is the *stripped* one: [ReplyInfo.body] has the `> `
      // quote already removed when the sender supplied the offsets, so storing
      // it keeps the bubble free of a duplicated quote.
      replyTo: Value(msg.reply?.targetId ?? ''),
      replyBody: Value(msg.reply?.body ?? ''),
      replyAuthor: Value(msg.from.toBare().toString()),
      // Never store the ciphertext of something we could not open: the
      // placeholder carries the failure, not the payload.
      body: Value(msg.encryptionError != null ? '' : msg.body),
      timestamp: Value(msg.archiveTimestamp ?? DateTime.now()),
      encMode: Value(
        // A message we could not open is a condition, not a track: the UI has
        // to say "this was encrypted, but not by us", and "none" would say
        // the opposite.
        msg.encryptionError != null
            ? EncModeToken.error.wire
            : EncModeToken.of(msg.track ?? Track.none).wire,
      ),
      incoming: const Value(true),
    ),
  );
}
