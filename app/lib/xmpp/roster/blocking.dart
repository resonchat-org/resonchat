// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Blocking a contact (XEP-0191).
//
// The reason this file exists is one sentence: **blocking stops us from acting
// as a reader and a signer for someone, and nothing else does.** The server
// still routes their messages. So the guarantee we can make is narrow and we
// should make exactly that one, rather than a broader one we cannot keep.
//
// Three consequences, each of which is a place a messenger gets it wrong:
//
//   * We do not decrypt their messages. Decrypting is the whole point of
//     holding the keys; a "blocked" client that quietly opens everything is
//     worse than one that shows nothing.
//   * We do not acknowledge them. No delivery receipt, no read marker, no
//     auto-reply. Each one is a signal that says "this person has an active
//     reader", and an acknowledgement is exactly what a blocked sender is
//     trying not to get.
//   * We do not send to them unless the user overrides it. Blocking and
//     sending are separate acts; a user who opens a blocked conversation and
//     types must be allowed to, because refusing silently is its own kind of
//     lie.

import 'package:moxxmpp/moxxmpp.dart' show JID;

import 'package:resonchat/persistence/database.dart';
import 'package:resonchat/xmpp/connection.dart';

/// One XEP-0191 push from the server (or another of our devices).
sealed class BlocklistChange {
  const BlocklistChange();
}

/// `<block><item jid='…'/>…</block>` — add these JIDs.
class BlocklistBlocked extends BlocklistChange {
  const BlocklistBlocked(this.jids);
  final Set<String> jids;
}

/// `<unblock><item jid='…'/>…</unblock>` — remove only these JIDs.
class BlocklistUnblocked extends BlocklistChange {
  const BlocklistUnblocked(this.jids);
  final Set<String> jids;
}

/// Empty `<unblock/>` — clear the entire list.
class BlocklistCleared extends BlocklistChange {
  const BlocklistCleared();
}

/// Why an inbound message from a blocked contact was not handled normally.
///
/// Not an error: the message arrived and was dealt with, which is exactly what
/// the user asked for. Surfaced so the UI can say so if asked, rather than
/// leaving the user to wonder whether blocking worked.
class BlockedMessageDropped {
  const BlockedMessageDropped({required this.from, required this.reason});

  final String from;

  /// 'decrypted', 'stored' or 'counted'.
  final String reason;

  @override
  String toString() => 'BlockedMessageDropped(from=$from, $reason)';
}

/// What the local block list looks like right now.
Future<Set<String>> blockedJids(AppDatabase db) => db.blockedJids();

/// True when [jid] is blocked.
Future<bool> isBlocked(AppDatabase db, String jid) => db.isBlocked(jid);

/// Blocks [jid] on the server and locally.
///
/// The local write happens first and is **not** rolled back if the server
/// refuses. A block that the user was told about and that the server did not
/// accept is still worth honouring on this device — the alternative is that a
/// server without XEP-0191 support (which is most of them) silently does
/// nothing, and "blocking did not work" is the worst possible outcome for the
/// action a user reaches for when they feel unsafe.
///
/// Returns true when the server accepted it.
Future<bool> blockContact(
  XmppService xmpp,
  AppDatabase db,
  String jid, {
  bool alsoUnfollow = true,
}) async {
  final bare = JID.fromString(jid).toBare().toString();
  await db.addBlocked(bare);
  // A block means we never want their presence request either.
  try {
    await xmpp.rejectSubscription(JID.fromString(bare));
  } catch (_) {}
  xmpp.resolveIncomingRequest(JID.fromString(bare));
  await db.resolveRequest(bare, outgoing: false);
  if (!alsoUnfollow) return false;
  return xmpp.blockOnServer([bare]);
}

/// Unblocks [jid] locally and, if it was blocked there, on the server.
///
/// The local removal is unconditional: a user who taps "unblock" must not be
/// told "still blocked" because the server was unreachable, or they will find
/// out the hard way.
Future<void> unblockContact(
  XmppService xmpp,
  AppDatabase db,
  String jid,
) async {
  final bare = JID.fromString(jid).toBare().toString();
  await db.removeBlocked(bare);
  await xmpp.unblockOnServer([bare]);
}

/// Merge the server's XEP-0191 list into the local store (add missing only).
///
/// Local-only blocks are kept: many servers lack Blocking and a replace would
/// erase the user's device-side decisions.
Future<void> mergeServerBlocklist(XmppService xmpp, AppDatabase db) async {
  final remote = await xmpp.fetchServerBlocklist();
  if (remote == null) return;
  for (final jid in remote) {
    final bare = JID.fromString(jid).toBare().toString();
    if (bare.isEmpty) continue;
    await db.addBlocked(bare);
  }
}

/// Applies a block pushed by our own server (XEP-0191 push).
///
/// From another of our devices, so it is as authoritative as tapping the
/// button here. Idempotent, because the server pushes the whole list and we
/// will see entries we already have.
Future<void> applyBlockPush(AppDatabase db, Set<String> pushed) async {
  for (final jid in pushed) {
    await db.addBlocked(jid);
  }
}

/// Applies an unblock push. An empty list means "unblock everything".
Future<void> applyUnblockPush(AppDatabase db, Set<String> pushed) async {
  if (pushed.isEmpty) {
    final all = await db.blockedJids();
    for (final jid in all) {
      await db.removeBlocked(jid);
    }
    return;
  }
  for (final jid in pushed) {
    await db.removeBlocked(jid);
  }
}

/// Whether a message from [from] may be decrypted.
///
/// The one hard guarantee of blocking: we do not open what the user asked us
/// not to open. Checking here rather than at the decryption call site means
/// there is exactly one place that can say no, and it is the place that reads
/// the block list.
bool mayDecrypt(Set<String> blocked, String from) => !blocked.contains(from);

/// Whether a message from [from] may be acknowledged.
///
/// Separate from [mayDecrypt] because the two fail differently. Not
/// decrypting is about our keys; not acknowledging is about telling a blocked
/// sender that somebody is reading. They are not the same promise and coupling
/// them means one of them ends up unenforced.
bool mayAcknowledge(Set<String> blocked, String from) =>
    !blocked.contains(from);

/// Whether an outgoing message to [to] may be sent without an override.
///
/// Returns true for unblocked contacts only. A send to a blocked contact is
/// possible, but only when the user explicitly went and did it — see
/// `overrideBlock` on the send path. Silently allowing a queued message through
/// would mean a message typed before the block lands after it, which is the
/// opposite of what blocking is for.
bool maySendWithoutOverride(Set<String> blocked, String to) =>
    !blocked.contains(to);
