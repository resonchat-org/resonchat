// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Conversations `QuoteHelper` + `MessageAdapter.handleTextQuotes` (line-oriented).

/// Conversations `Config.QUOTE_MAX_DEPTH`.
const kQuoteMaxDepth = 7;

/// A run of body text after quote markers are stripped.
class BodyBlock {
  const BodyBlock({required this.text, required this.quoteDepth});

  final String text;

  /// 0 = normal; ≥1 quote nesting (each level draws a Conversations bar).
  final int quoteDepth;
}

/// Whether [pos] starts a quote line (Conversations `QuoteHelper.isPositionQuoteStart`).
bool isQuoteStart(String body, int pos) {
  if (pos < 0 || pos >= body.length) return false;
  if (!_precededByPreQuote(body, pos)) return false;
  if (!_isQuoteCharacter(body, pos)) return false;
  return _followedByQuoteable(body, pos) || _followedByQuoteChar(body, pos);
}

bool bodyContainsQuoteStart(String body) {
  for (var i = 0; i < body.length; i++) {
    if (isQuoteStart(body, i)) return true;
  }
  return false;
}

/// Split [raw] into blocks with quote depth (markers removed).
///
/// Mirrors Conversations peeling one `>` / `»` level at a time up to
/// [kQuoteMaxDepth], then groups consecutive equal-depth runs.
List<BodyBlock> parseBodyBlocks(String raw) {
  if (raw.isEmpty) return const [];

  final lines = raw.split('\n');
  final depths = <int>[];
  final cleaned = <String>[];

  for (final line in lines) {
    var rest = line;
    var depth = 0;
    while (depth < kQuoteMaxDepth && isQuoteStart(rest, 0)) {
      rest = _stripOneQuoteMarker(rest);
      depth++;
    }
    depths.add(depth);
    cleaned.add(rest);
  }

  final blocks = <BodyBlock>[];
  var i = 0;
  while (i < cleaned.length) {
    final d = depths[i];
    final buf = StringBuffer(cleaned[i]);
    var j = i + 1;
    while (j < cleaned.length && depths[j] == d) {
      buf.write('\n');
      buf.write(cleaned[j]);
      j++;
    }
    blocks.add(BodyBlock(text: buf.toString(), quoteDepth: d));
    i = j;
  }
  return blocks;
}

/// Strip one leading quote marker and following spaces (Conversations delete).
String _stripOneQuoteMarker(String line) {
  if (line.isEmpty || !isQuoteStart(line, 0)) return line;
  var i = 1;
  while (i < line.length && line[i] == ' ') {
    i++;
  }
  // Avoid empty lines — Conversations inserts a space so the span stays visible.
  if (i >= line.length) return ' ';
  return line.substring(i);
}

/// Conversations `QuoteHelper.isPositionQuoteCharacter`.
bool _isQuoteCharacter(String body, int pos) {
  final c = body[pos];
  if (c == '>') return true;
  // Alt quote only when it is a real start (not `»…«`).
  if (c == '»') {
    return _precededByPreQuote(body, pos) && !_followedByAltQuoteEnd(body, pos);
  }
  return false;
}

bool _followedByQuoteChar(String body, int pos) =>
    pos + 1 < body.length && _isQuoteCharacter(body, pos + 1);

bool _precededByPreQuote(String body, int pos) {
  if (pos == 0) return true;
  if (body[pos - 1] == '\n') return true;
  for (var i = pos - 1; i >= 0; i--) {
    if (body[i] != ' ') return false;
  }
  return true;
}

bool _followedByQuoteable(String body, int pos) =>
    !_followedByNumber(body, pos) &&
    !_followedByEmoticon(body, pos) &&
    !_followedByEquals(body, pos);

bool _followedByEquals(String body, int pos) =>
    pos + 1 < body.length && body[pos + 1] == '=';

bool _followedByNumber(String body, int pos) {
  var previousWasNumber = false;
  for (var i = pos + 1; i < body.length; i++) {
    final c = body[i];
    if (_isDigit(c)) {
      previousWasNumber = true;
    } else if (previousWasNumber && (c == '.' || c == ',')) {
      previousWasNumber = false;
    } else {
      return (c.trim().isEmpty || c == '%' || c == '+') && previousWasNumber;
    }
  }
  return previousWasNumber;
}

bool _followedByEmoticon(String body, int pos) {
  if (pos + 1 >= body.length) return false;
  final first = body[pos + 1];
  return first == ';' ||
      first == ':' ||
      first == '.' ||
      _closingBeforeWhitespace(body, pos + 1);
}

/// Conversations `UIHelper.closingBeforeWhitespace`.
bool _closingBeforeWhitespace(String body, int pos) {
  for (var i = pos; i < body.length; i++) {
    final c = body[i];
    if (c.trim().isEmpty) return false;
    // Intentionally [pos] (not [i]) — matches Conversations.
    if (_isQuoteCharacter(body, pos) || body[pos] == '<') {
      return i + 1 >= body.length || body[i + 1].trim().isEmpty;
    }
  }
  return false;
}

bool _followedByAltQuoteEnd(String body, int pos) {
  if (pos + 1 >= body.length || body[pos + 1].trim().isEmpty) return false;
  var previousWasWhitespace = false;
  for (var i = pos + 1; i < body.length; i++) {
    final c = body[i];
    if (c == '\n' || c == '»') return false;
    if (c == '«' && !previousWasWhitespace) return true;
    previousWasWhitespace = c.trim().isEmpty;
  }
  return false;
}

bool _isDigit(String c) {
  final u = c.codeUnitAt(0);
  return u >= 0x30 && u <= 0x39;
}
