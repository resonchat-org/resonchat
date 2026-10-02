// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Retracting a message for everyone (XEP-0424), and correcting one
// (XEP-0308).
//
// The two share a shape — "a later instruction about an earlier message" —
// and differ in one way that decides everything about how they travel:
//
//   * A retraction is **metadata**. It says "this message is gone"; the
//     recipient's client has to be able to act on it, and it must work
//     whether or not it can decrypt. So it goes out in the clear, carrying a
//     fallback body for clients that show something anyway.
//   * A correction **is** the new content. Encrypting it is the whole point —
//     a correction that leaks the corrected text to the server would be worse
//     than no correction. So it goes out through the ordinary encrypted path.
//
// Both address a message by its origin-id (XEP-0359). Neither may be applied
// to a message we cannot identify: an instruction naming an id we do not hold
// is either out of order or aimed at someone else's copy, and acting on it
// anyway would let one sender blank a stranger's message.

import 'package:moxxmpp/moxxmpp.dart' show JID;

import '../omemo/track.dart';
import '../store/database.dart';
import 'connection.dart';

/// Shown in place of a retracted message.
///
/// Says who did it, so a reader who saw the message before it vanished is not
/// left wondering whether their own client failed.
const kRetractedNotice = 'This message was deleted';

/// Shown in place of a retracted message that we sent.
///
/// Deliberately different wording: being unable to retract is a failure the
/// person who hit the button needs to know about, and the sender's own copy is
/// the only place that can say so.
const kRetractedNoticeMine = 'You deleted this message';

/// Retracts the message addressed by [targetId] for everyone in [chatJid].
///
/// Returns false when the stanza could not be sent, or when [targetId] is
/// empty. An empty id means the message was never addressable — most often a
/// message from before this build added origin-ids — and retracting "the last
/// message" instead would remove a different one.
Future<bool> retractMessage(
  XmppService xmpp, {
  required String chatJid,
  required String targetId,
}) {
  if (targetId.isEmpty) return Future.value(false);
  return xmpp.retractMessage(
    JID.fromString(chatJid).toBare(),
    targetId: targetId,
  );
}

/// Applies a retraction that arrived, and reports whether it changed anything.
Future<bool> applyRetraction(AppDatabase db, String targetId) =>
    db.markRetracted(targetId);

/// Replaces the content of the message addressed by [targetId].
///
/// Idempotent in both directions, so the caller does not have to know whether
/// the original arrived yet.
Future<void> correctMessage({
  required AppDatabase db,
  required String chatJid,
  required String targetId,
  required String body,
  required Track track,
}) {
  return db.applyCorrection(
    chatJid: chatJid,
    targetId: targetId,
    body: body,
    encMode: EncModeToken.of(track).wire,
  );
}