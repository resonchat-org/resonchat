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
  var rest = receivedBody.replaceRange(range.start, range.end, '');
  // Conversations/monocles separate the quote from the reply with a blank
  // line. The card already provides that gap, so do not store it in the body.
  if (range.start == 0 && range.end > range.start) {
    while (rest.startsWith('\n')) {
      rest = rest.substring(1);
    }
  }
  return rest;
}

/// Quoted prose for [ReplyInfo.body] / the reply card (no `> ` markers).
String quoteFromReply(ReplyData data, String receivedBody) {
  final range = _fallbackRange(data, receivedBody);
  if (range == null) return '';
  return unquoteFallback(receivedBody.substring(range.start, range.end));
}

/// XEP-0461 offsets are code points, while Dart strings are UTF-16.
///
/// A quote containing an emoji is two code units long but one code point. Using
/// the wire offset directly as a string index would cut the quote one character
/// short (or throw) the moment the quoted text leaves the BMP.
({int start, int end})? _fallbackRange(ReplyData data, String receivedBody) {
  final start = data.start;
  final end = data.end;
  if (start == null || end == null) return null;
  if (start < 0 || end < start) return null;
  final startIndex = _codeUnitIndex(receivedBody, start);
  final endIndex = _codeUnitIndex(receivedBody, end);
  if (startIndex == null || endIndex == null) return null;
  return (start: startIndex, end: endIndex);
}

/// UTF-16 index for a code-point offset, or null when out of range.
int? _codeUnitIndex(String text, int codePointOffset) {
  if (codePointOffset < 0) return null;
  var index = 0;
  var codePoints = 0;
  for (final rune in text.runes) {
    if (codePoints == codePointOffset) return index;
    index += rune > 0xFFFF ? 2 : 1;
    codePoints++;
  }
  return codePoints == codePointOffset ? index : null;
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
