// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:moxxmpp/moxxmpp.dart' show ReplyData;

/// The XEP-0461 reply metadata carried by one inbound message.
class ReplyInfo {
  const ReplyInfo({required this.targetId, required this.body});

  /// Origin-id of the message being replied to.
  final String targetId;

  /// The quoted text, with the `> ` fallback prefixes removed when the sender
  /// provided the offsets that let us strip them.
  final String body;

  factory ReplyInfo.from(ReplyData data, String receivedBody) {
    return ReplyInfo(
      targetId: data.id,
      body: stripFallback(data, receivedBody),
    );
  }
}

/// Removes the quoted prefix from [receivedBody], if there is one.
///
/// The offsets arrive from the other end, and moxxmpp's own
/// `ReplyData.withoutFallback` calls `String.replaceRange` with them
/// unchecked — so a sender claiming `end = 65535` on a twelve-character body
/// throws a RangeError inside our parser. That is a remote way to crash this
/// client, and it costs three lines to refuse it.
///
/// The offsets are also only honoured when they actually describe a quote.
/// A sender that sent no `<fallback>` gives us no way to tell where the quote
/// ends, and guessing would cut the reply itself in half — so the body is left
/// alone, which is the honest answer.
String stripFallback(ReplyData data, String receivedBody) {
  final start = data.start;
  final end = data.end;
  if (start == null || end == null) return receivedBody;
  if (start < 0 || end < start || end > receivedBody.length) {
    // Out of range. Refusing to guess is better than throwing or, worse,
    // silently mangling a message someone actually wrote.
    return receivedBody;
  }
  return receivedBody.replaceRange(start, end, '');
}
