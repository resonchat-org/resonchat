// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Replies to a specific message (XEP-0461).
//
// The mechanism has two halves that carry very different weight:
//
//   * The XEP-0461 `<reply>` element, which points at the target's origin-id.
//     It is metadata and goes in the clear, like reactions and retractions —
//     the recipient's client has to be able to line the reply up with what it
//     is replying to.
//   * The quoted text itself, in a `> `-prefixed fallback body, because that is
//     what every client shows and what a plain-text reader can still read.
//
// The fallback is **also** how a reply can be read by something that knows
// nothing about XEPs, and that is not a concession: it is the reason the
// fallback exists. But it must not be the only source of the quote here — the
// body is copied onto the stored row, because the quoted message is exactly
// the thing most likely to disappear (a retraction is one tap away), and a
// quote that empties out when its target is deleted is a broken quote.

import 'package:moxxmpp/moxxmpp.dart'
    show JID, ReplyData, XMLNode, fallbackIndicationXmlns, replyXmlns;

import 'package:resonchat/crypto/dual/track.dart';
import 'package:resonchat/xmpp/connection.dart';

export 'package:resonchat/xmpp/inbound/reply_info.dart'
    show ReplyInfo, quoteFromReply, stripFallback;

/// The quoted text plus the offsets that say where the quote ends.
///
/// A reply body is the quote, `> `-prefixed, then the reply. The offsets are
/// what lets the receiving side strip the quote back off — without them a
/// reader cannot tell a quoted line from the first line of the reply, so the
/// reply arrives looking like a quotation of itself.
class ReplyFallback {
  const ReplyFallback({
    required this.wireBody,
    required this.start,
    required this.end,
  });

  /// The full body as it goes on the wire, quote included.
  final String wireBody;

  final int start;
  final int end;
}

/// Builds the fallback for a reply quoting [quote].
///
/// Matches monocles/Conversations: each quoted line is trimmed, every line is
/// prefixed with `> `, and a blank line separates the quote from the reply.
/// The returned offsets are code points (XEP-0461), not UTF-16 code units.
ReplyFallback buildReplyFallback(String quote, String body) {
  if (quote.isEmpty) {
    // `''.split('\n')` is `['']`, which would emit a bare "> " line: a quote
    // of nothing, reading as a truncation of the message above it.
    return ReplyFallback(wireBody: body, start: 0, end: 0);
  }
  final quoted = quote.split('\n').map((line) => '> ${line.trim()}\n').join();
  return ReplyFallback(
    wireBody: '$quoted\n$body',
    start: 0,
    end: quoted.runes.length,
  );
}

/// Builds the XEP-0461 elements for a reply.
///
/// Needed only where the stanza is assembled by hand: moxxmpp's
/// MessageManager builds these itself from a [ReplyData] extension, but the
/// plaintext path bypasses the manager so it can state `shouldEncrypt: false`
/// on the stanza.
///
/// The `<fallback>` offsets are what let a receiver strip the quote back off.
/// Emitting the quote without them would make the reply look like a quotation
/// of itself.
List<XMLNode> replyNodes({
  required String targetId,
  required ReplyFallback fallback,
}) {
  // Only `<reply>` + `<fallback>`. One `<body/>` (quote fallback + reply) is
  // already on the stanza via [MessageBodyData] — same as Conversations.
  return [
    XMLNode.xmlns(
      tag: 'reply',
      xmlns: replyXmlns,
      attributes: {'id': targetId},
    ),
    XMLNode.xmlns(
      tag: 'fallback',
      xmlns: fallbackIndicationXmlns,
      attributes: {'for': replyXmlns},
      children: [
        XMLNode(
          tag: 'body',
          attributes: {
            'start': fallback.start.toString(),
            'end': fallback.end.toString(),
          },
        ),
      ],
    ),
  ];
}

/// Sends [body] as a reply to the message addressed by [targetId].
///
/// Returns an outcome with `sent == false` when the chosen track was blocked;
/// nothing goes out in that case and the caller's text stays where it is. A
/// reply that silently became a plain message would lose the only thing that
/// made it a reply, and the reader would have no way to know.
///
/// [quoteBody] is copied onto the stored row so the quote survives its target
/// being retracted or never loaded. Callers store it themselves; this function
/// only decides what goes on the wire.
Future<SendOutcome> sendReply(
  XmppService xmpp, {
  required JID to,
  required String body,
  required String targetId,
  required Track track,
  String? quoteBody,
  String messageType = 'chat',
  String? originId,
}) async {
  final outcome = await xmpp.sendOnTrack(
    to,
    body,
    track: track,
    replyTo: targetId.isEmpty ? null : targetId,
    quoteBody: quoteBody,
    messageType: messageType,
    originId: originId,
  );
  return outcome;
}
