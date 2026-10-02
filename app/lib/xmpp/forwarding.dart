// Copyright (C) 2026 resonchat contributors.
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
// new conversation's track, carrying the original's text as a `> ` quote. That
// is what every client the user knows actually does, and it composes with the
// three-track design instead of fighting it.
//
// One thing reuse would have given us and this does not: the original's
// ciphertext is not re-sent. That is correct, not a loss. The recipient of a
// forward should read what the sender chose to forward, not hold a copy of an
// encryption the sender has no reason to re-issue.

import 'package:moxxmpp/moxxmpp.dart' show JID;

import '../omemo/track.dart';
import 'connection.dart';
import 'replies.dart';

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
  });

  /// How many messages actually went out.
  final int forwarded;

  /// Null when everything was sent.
  final ForwardRefusal? refused;

  /// Stanza ids of what was sent, so the caller can store or roll back.
  final List<String> stanzaId;

  bool get ok => refused == null;
}

/// One message chosen for forwarding.
class ForwardItem {
  const ForwardItem({required this.body, required this.chatJid});

  /// The text to forward.
  ///
  /// The stored body, already stripped of any `> ` quote it was itself a reply
  /// to — forwarding the quote of a quote produces an unreadable block that
  /// grows on every hop.
  final String body;

  /// Where it came from, named in the attribution so the recipient knows it is
  /// second-hand.
  final String chatJid;
}

/// The text to put on the wire as the attribution.
String forwardAttribution(String originJid) => 'Forwarded from $originJid';

/// Sends one message of a forward. Injected so the loop can be tested without
/// a connection.
typedef ForwardSender =
    Future<SendOutcome> Function(String body, String quote, Track track);

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
  for (final item in items) {
    final outcome = await send(
      forwardAttribution(item.chatJid),
      item.body,
      track,
    );
    if (!outcome.sent) {
      return ForwardOutcome(
        forwarded: sent.length,
        refused: ForwardRefusal.trackBlocked,
        stanzaId: sent,
      );
    }
    if (outcome.stanzaId != null) sent.add(outcome.stanzaId!);
  }
  return ForwardOutcome(forwarded: sent.length, stanzaId: sent);
}

/// Forwards [items] into the conversation with [toJid].
Future<ForwardOutcome> forwardMessages(
  XmppService xmpp, {
  required JID toJid,
  required List<ForwardItem> items,
  required Track track,
}) {
  return runForward(
    items: items,
    track: track,
    send: (body, quote, t) => sendReply(
      xmpp,
      to: toJid,
      body: body,
      // Empty: a forward references no message of its own. The quoted text is
      // attribution, not a reply target, and pointing a `<reply>` element at
      // nothing would make some clients render an empty quote box.
      targetId: '',
      track: t,
      quoteBody: quote,
    ),
  );
}