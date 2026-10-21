// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Forwarding a message to another conversation.
//
// Why this does not use XEP-0297's `<forwarded/>` wrapper, which exists
// precisely for this and which moxxmpp can parse and build:
//
//   A wrapped stanza carries the *original* encryption. Its payload was
//   encrypted to the original recipient's keys, so wrapping it and sending it
//   to a third party hands that third party a ciphertext they cannot open —
//   and the wrapper's metadata still names the original recipient, which tells
//   the new one who they were talking to.
//
//   That is not a cosmetic difference. Forwarding by reuse would mean the
//   forward either fails silently or leaks who else was in the conversation.
//
// So a forward is a **new message**, re-encrypted for the new recipient on the
// new conversation's track. Classic items use a `> `-quoted body plus a short
// attribution line; preformatted items (quoted transcripts) are sent as-is.

import 'package:moxxmpp/moxxmpp.dart' show JID;

import 'package:resonchat/crypto/dual/track.dart';
import 'package:resonchat/xmpp/chat/replies.dart';
import 'package:resonchat/xmpp/connection.dart';

/// Why a forward could not be sent.
enum ForwardRefusal {
  /// Nothing was selected to forward.
  nothingSelected,

  /// The destination conversation's track is blocked for this peer.
  trackBlocked,
}

/// The outcome of one forward.
class ForwardOutcome {
  const ForwardOutcome({
    required this.forwarded,
    this.refused,
    this.stanzaId = const [],
    this.wireBodies = const [],
  });

  /// How many messages actually went out.
  final int forwarded;

  /// Null when everything was sent.
  final ForwardRefusal? refused;

  /// Stanza ids of what was sent, so the caller can store or roll back.
  final List<String> stanzaId;

  /// Wire bodies matching [stanzaId] (for local persistence).
  final List<String> wireBodies;

  bool get ok => refused == null;
}

/// One message chosen for forwarding.
class ForwardItem {
  const ForwardItem({
    required this.body,
    required this.chatJid,
    this.preformatted = false,
  });

  /// The text to forward.
  ///
  /// When [preformatted] is false: the stored body (no nested quote of a quote).
  /// When true: a full transcript (headers + `> ` lines), sent as the message
  /// body without wrapping again.
  final String body;

  /// Where it came from, named in the attribution so the recipient knows it is
  /// second-hand. Unused when [preformatted].
  final String chatJid;

  /// [body] is already the wire text; do not add attribution / extra quoting.
  final bool preformatted;
}

/// The text to put on the wire as the attribution.
String forwardAttribution(String originJid) => 'Forwarded from $originJid';

/// Builds the body that actually goes on the wire for one [item].
String forwardWireBody(ForwardItem item) {
  if (item.preformatted) return item.body;
  // Attribution after the quote (same shape as a reply fallback): readers see
  // the quoted content first, then the label. Must not go through sendReply
  // with an empty targetId — that path drops the quote when replyTo is null.
  return buildReplyFallback(
    item.body,
    forwardAttribution(item.chatJid),
  ).wireBody;
}

/// Sends one message of a forward. Injected so the loop can be tested without
/// a connection.
typedef ForwardSender = Future<SendOutcome> Function(
  String wireBody,
  Track track,
);

/// Runs the forward loop.
///
/// Stops at the first refusal and reports how many went out: a partial forward
/// the user is not told about is indistinguishable from one that failed
/// outright, and they are the only one who can tell the difference.
Future<ForwardOutcome> runForward({
  required List<ForwardItem> items,
  required Track track,
  required ForwardSender send,
}) async {
  if (items.isEmpty) {
    return const ForwardOutcome(
      forwarded: 0,
      refused: ForwardRefusal.nothingSelected,
    );
  }
  final sent = <String>[];
  final bodies = <String>[];
  for (final item in items) {
    final wire = forwardWireBody(item);
    final outcome = await send(wire, track);
    if (!outcome.sent) {
      return ForwardOutcome(
        forwarded: sent.length,
        refused: ForwardRefusal.trackBlocked,
        stanzaId: sent,
        wireBodies: bodies,
      );
    }
    if (outcome.stanzaId != null) {
      sent.add(outcome.stanzaId!);
      bodies.add(wire);
    }
  }
  return ForwardOutcome(
    forwarded: sent.length,
    stanzaId: sent,
    wireBodies: bodies,
  );
}

/// Forwards [items] into the conversation with [toJid].
Future<ForwardOutcome> forwardMessages(
  XmppService xmpp, {
  required JID toJid,
  required List<ForwardItem> items,
  required Track track,
  String messageType = 'chat',
}) {
  return runForward(
    items: items,
    track: track,
    send: (wireBody, t) =>
        xmpp.sendOnTrack(toJid, wireBody, track: t, messageType: messageType),
  );
}
