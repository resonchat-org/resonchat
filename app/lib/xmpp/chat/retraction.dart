// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
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
//     fallback body that supporting clients do not display.
//   * A correction **is** the new content. Encrypting it is the whole point —
//     a correction that leaks the corrected text to the server would be worse
//     than no correction. So it goes out through the ordinary encrypted path.
//
// Both address a message by its origin-id (XEP-0359). Neither may be applied
// to a message we cannot identify: an instruction naming an id we do not hold
// is either out of order or aimed at someone else's copy, and acting on it
// anyway would let one sender blank a stranger's message.

import 'package:moxxmpp/moxxmpp.dart' show JID;

import 'package:resonchat/crypto/dual/track.dart';
import 'package:resonchat/domain/messages_service.dart';
import 'package:resonchat/xmpp/connection.dart';

/// Retracts the message addressed by [targetId] for everyone in [chatJid].
///
/// Returns false when the stanza could not be sent, or when [targetId] is
/// empty. An empty id means the message was never addressable — most often a
/// message from before this build added origin-ids — and retracting "the last
/// message" instead would remove a different one.
///
/// [groupchat] sends `type='groupchat'`. [targetId] is then the room's
/// stanza-id when we have one.
Future<bool> retractMessage(
  XmppService xmpp, {
  required String chatJid,
  required String targetId,
  bool groupchat = false,
}) {
  if (targetId.isEmpty) return Future.value(false);
  return xmpp.retractMessage(
    JID.fromString(chatJid).toBare(),
    targetId: targetId,
    groupchat: groupchat,
  );
}

/// Applies a retraction that arrived, and reports whether it changed anything.
///
/// [by] is the moderator's nick when the retraction is XEP-0425.
/// [reason] is omitted when the moderator gave none.
Future<bool> applyRetraction(
  MessagesService messages,
  String targetId, {
  String? by,
  String? reason,
}) => messages.applyRetraction(targetId, by: by, reason: reason);

/// Replaces the content of the message addressed by [targetId].
///
/// Idempotent in both directions, so the caller does not have to know whether
/// the original arrived yet.
Future<void> correctMessage({
  required MessagesService messages,
  required String chatJid,
  required String targetId,
  required String body,
  required Track track,
}) {
  return messages.correctMessage(
    chatJid: chatJid,
    targetId: targetId,
    body: body,
    track: track,
  );
}
