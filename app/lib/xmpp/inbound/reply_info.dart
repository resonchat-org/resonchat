// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:moxxmpp/moxxmpp.dart' show ReplyData;

/// The XEP-0461 reply metadata carried by one inbound message.
class ReplyInfo {
  const ReplyInfo({required this.targetId, required this.body});

  /// Origin-id of the message being replied to.
  final String targetId;

  /// The quoted text shown above the bubble ([Messages.replyBody]).
  ///
  /// Taken from the fallback range with `> ` markers removed — not the reply
  /// itself. The reply body is [stripFallback] applied to the wire body.
  final String body;

  factory ReplyInfo.from(ReplyData data, String receivedBody) {
    return ReplyInfo(
      targetId: data.id,
      body: quoteFromReply(data, receivedBody),
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
  final range = _fallbackRange(data, receivedBody);
  if (range == null) return receivedBody;
  return receivedBody.replaceRange(range.start, range.end, '');
}

/// Quoted prose for [ReplyInfo.body] / the reply card (no `> ` markers).
String quoteFromReply(ReplyData data, String receivedBody) {
  final range = _fallbackRange(data, receivedBody);
  if (range == null) return '';
  return unquoteFallback(receivedBody.substring(range.start, range.end));
}

({int start, int end})? _fallbackRange(ReplyData data, String receivedBody) {
  final start = data.start;
  final end = data.end;
  if (start == null || end == null) return null;
  if (start < 0 || end < start || end > receivedBody.length) return null;
  return (start: start, end: end);
}

/// Strips Conversations-style `> ` line prefixes from a fallback region.
String unquoteFallback(String region) {
  final lines = region.split('\n');
  final out = <String>[];
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    // Trailing empty from a final `\n` on the last quoted line.
    if (i == lines.length - 1 && line.isEmpty) break;
    if (line.startsWith('> ')) {
      out.add(line.substring(2));
    } else if (line == '>') {
      out.add('');
    } else {
      out.add(line);
    }
  }
  return out.join('\n');
}
