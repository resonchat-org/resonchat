// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Unified message-body styling modelled on Gajim `common/styling.py`
// (XEP-0393 blocks + spans + URI/JID linkify).

import 'package:moxxmpp/moxxmpp.dart' show JID;

/// Gajim `MAX_QUOTE_LEVEL`.
const kMaxQuoteLevel = 20;

/// Span keyword / kind.
enum StyleKind { strong, emphasis, strike, pre }

/// One inline style span (half-open [start, end); includes markers).
class StyleSpan {
  const StyleSpan({required this.kind, required this.start, required this.end});

  final StyleKind kind;
  final int start;
  final int end;
}

/// One hyperlink / bare JID (half-open [start, end)).
class StyleLink {
  const StyleLink({
    required this.start,
    required this.end,
    required this.url,
    required this.text,
  });

  final int start;
  final int end;

  /// Activation target (`https://…`, `mailto:…`, `xmpp:jid`, …).
  final String url;
  final String text;
}

/// Top-level / nested content block.
sealed class StyleBlock {
  const StyleBlock({
    required this.start,
    required this.end,
    required this.text,
  });
  final int start;
  final int end;
  final String text;
}

/// Ordinary text with spans and links.
class PlainBlock extends StyleBlock {
  const PlainBlock({
    required super.start,
    required super.end,
    required super.text,
    this.spans = const [],
    this.uris = const [],
  });

  final List<StyleSpan> spans;
  final List<StyleLink> uris;
}

/// Fenced ``` code block (raw includes fences).
class PreBlock extends StyleBlock {
  const PreBlock({
    required super.start,
    required super.end,
    required super.text,
  });

  /// Gajim `CodeWidget._prepare_code`.
  ({String code, String? language}) get prepared {
    final stripped = text.trim();
    final nl = stripped.indexOf('\n');
    if (nl < 0) return (code: '', language: null);
    final first = stripped.substring(0, nl);
    final language = first.length > 3 ? first.substring(3).trim() : null;
    var body = stripped.substring(nl + 1);
    if (body.endsWith('```')) {
      body = body.substring(0, body.length - 3);
      if (body.endsWith('\n')) body = body.substring(0, body.length - 1);
    }
    final lang = switch (language) {
      null || '' => null,
      'python' => 'python3',
      final other => other,
    };
    return (code: body, language: lang);
  }
}

/// Block quote (`>` / `»`); [blocks] are nested after unquoting.
class QuoteBlock extends StyleBlock {
  QuoteBlock({
    required super.start,
    required super.end,
    required super.text,
    List<StyleBlock>? blocks,
  }) : blocks = blocks ?? [];

  List<StyleBlock> blocks;

  String unquote() => text.replaceAll(_unquoteRx, '');
}

class ParsingResult {
  const ParsingResult({required this.text, required this.blocks});
  final String text;
  final List<StyleBlock> blocks;
}

// Gajim PRE_RX / PRE_NESTED_RX / QUOTE_RX (also accept Conversations `»`).
final _preRx = RegExp(
  r'^```[^\n]*\n.*?^```[ \t]*(?:\n|$)',
  multiLine: true,
  dotAll: true,
);
final _preNestedRx = RegExp(
  r'^```[^\n]*\n.*?(?:^```[ \t]*(?:\n|$)|$)',
  multiLine: true,
  dotAll: true,
);

/// Consecutive lines starting with `>` / `»` (Gajim QUOTE_RX; Dart has no `\Z`).
final _quoteRx = RegExp(r'^(?:[>»].*(?:\n|$))+', multiLine: true);
final _unquoteRx = RegExp(r'^[>»] ?', multiLine: true);

final _uriOrJidRx = RegExp(
  r'''(?<![\w+.-])(?:https?|mailto|xmpp|ftp|ftps|geo|tel):[^\s<>"']+|www\.[^\s<>"']+|[^\s@<>"']+@[^\s@<>"']+''',
  caseSensitive: false,
);

const _spanDirs = {'*', '_', '~', '`'};

bool _isWs(String ch) => ch.trim().isEmpty;

/// Gajim `process` — blocks, then spans/uris on plain lines, recurse quotes.
ParsingResult processMessageStyling(String text, {int level = 0}) {
  final rawBlocks = _parseBlocks(text, level);
  final blocks = <StyleBlock>[];
  for (final block in rawBlocks) {
    if (block is PlainBlock) {
      var offset = 0;
      final spans = <StyleSpan>[];
      final uris = <StyleLink>[];
      for (final line in _splitKeepEnds(block.text)) {
        spans.addAll(_parseLine(line, offset));
        uris.addAll(_parseUris(line, offset));
        offset += line.length;
      }
      blocks.add(
        PlainBlock(
          start: block.start,
          end: block.end,
          text: block.text,
          spans: spans,
          uris: uris,
        ),
      );
    } else if (block is QuoteBlock) {
      final nested = processMessageStyling(block.unquote(), level: level + 1);
      blocks.add(
        QuoteBlock(
          start: block.start,
          end: block.end,
          text: block.text,
          blocks: nested.blocks,
        ),
      );
    } else {
      blocks.add(block);
    }
  }
  return ParsingResult(text: text, blocks: blocks);
}

/// URI/JID scan only (Gajim `process_uris`).
List<StyleLink> processUris(String text) {
  final uris = <StyleLink>[];
  var offset = 0;
  for (final line in _splitKeepEnds(text)) {
    uris.addAll(_parseUris(line, offset));
    offset += line.length;
  }
  return uris;
}

List<StyleBlock> _parseBlocks(String text, int level) {
  final blocks = <StyleBlock>[];
  final textLen = text.length;
  var lastEnd = 0;
  final preRx = level > 0 ? _preNestedRx : _preRx;

  final hits = <({int start, int end, String kind, String text})>[];
  for (final m in preRx.allMatches(text)) {
    hits.add((start: m.start, end: m.end, kind: 'pre', text: m.group(0)!));
  }
  for (final m in _quoteRx.allMatches(text)) {
    hits.add((start: m.start, end: m.end, kind: 'quote', text: m.group(0)!));
  }
  hits.sort((a, b) => a.start.compareTo(b.start));

  var cursor = 0;
  for (final h in hits) {
    if (h.start < cursor) continue;
    if (h.start != lastEnd) {
      blocks.add(
        PlainBlock(
          start: lastEnd,
          end: h.start,
          text: text.substring(lastEnd, h.start),
        ),
      );
    }
    lastEnd = h.end;
    cursor = h.end;
    if (h.kind == 'quote') {
      if (level >= kMaxQuoteLevel) {
        blocks.add(PlainBlock(start: h.start, end: h.end, text: h.text));
      } else {
        blocks.add(QuoteBlock(start: h.start, end: h.end, text: h.text));
      }
    } else {
      blocks.add(PreBlock(start: h.start, end: h.end, text: h.text));
    }
  }
  if (lastEnd != textLen) {
    blocks.add(
      PlainBlock(start: lastEnd, end: textLen, text: text.substring(lastEnd)),
    );
  }
  return blocks;
}

List<StyleSpan> _parseLine(String line, int offset) {
  var index = 0;
  final length = line.length;
  final stack = <(String, int)>[];
  final spans = <StyleSpan>[];

  while (index < length) {
    final sd = line[index];
    if (!_spanDirs.contains(sd)) {
      index++;
      continue;
    }

    var isValidStart = _isValidSpanStart(line, index);
    final isValidEnd = _isValidSpanEnd(line, index);

    if (isValidStart && isValidEnd) {
      if (stack.any((e) => e.$1 == sd)) {
        isValidStart = false;
      }
    }

    if (isValidStart) {
      if (sd == '`') {
        index = _handlePreSpan(line, index, offset, spans);
        continue;
      }
      stack.add((sd, index));
      index++;
      continue;
    }

    if (isValidEnd) {
      if (!stack.any((e) => e.$1 == sd)) {
        index++;
        continue;
      }
      if (_isSpanEmpty(sd, index, stack)) {
        stack.removeLast();
        index++;
        continue;
      }
      final startPos = _findSpanStart(sd, stack);
      spans.add(_makeSpan(sd, startPos, index, offset));
    }
    index++;
  }
  return spans;
}

int _handlePreSpan(String line, int index, int offset, List<StyleSpan> spans) {
  final end = line.indexOf('`', index + 1);
  if (end == -1) return index + 1;
  if (end - index == 1) return index + 1;
  spans.add(_makeSpan('`', index, end, offset));
  return end + 1;
}

StyleSpan _makeSpan(String sd, int start, int end, int offset) {
  final kind = switch (sd) {
    '*' => StyleKind.strong,
    '_' => StyleKind.emphasis,
    '~' => StyleKind.strike,
    '`' => StyleKind.pre,
    _ => StyleKind.strong,
  };
  return StyleSpan(kind: kind, start: start + offset, end: end + offset + 1);
}

List<StyleLink> _parseUris(String line, int offset) {
  final uris = <StyleLink>[];
  for (final m in _uriOrJidRx.allMatches(line)) {
    var start = m.start;
    var end = m.end;
    if (end > start && line[end - 1] == ',') end--;
    if (line.substring(0, start).contains('(') &&
        end > start &&
        line[end - 1] == ')') {
      end--;
    }
    final matched = line.substring(start, end);
    if (RegExp(r'^[^:]+:$').hasMatch(matched)) continue;

    final isJid = matched.contains('@') && !matched.contains(':');
    final link = _makeHyperlink(matched, start + offset, end + offset, isJid);
    if (link != null) uris.add(link);
  }
  return uris;
}

StyleLink? _makeHyperlink(String text, int start, int end, bool isJid) {
  if (isJid) {
    try {
      final jid = JID.fromString(text);
      if (jid.local.isEmpty || jid.domain.isEmpty) return null;
    } catch (_) {
      return null;
    }
    return StyleLink(start: start, end: end, url: 'xmpp:$text', text: text);
  }

  final lower = text.toLowerCase();
  if (lower.startsWith('www.')) {
    return StyleLink(start: start, end: end, url: 'https://$text', text: text);
  }
  final scheme = Uri.tryParse(text)?.scheme;
  if (scheme == null || scheme.isEmpty) return null;
  const ok = {'http', 'https', 'mailto', 'xmpp', 'ftp', 'ftps', 'geo', 'tel'};
  if (!ok.contains(scheme.toLowerCase())) return null;

  return StyleLink(start: start, end: end, url: text, text: text);
}

bool _isSpanEmpty(String sd, int index, List<(String, int)> stack) {
  if (stack.isEmpty) return false;
  final (startSd, pos) = stack.last;
  if (startSd != sd) return false;
  return pos == index - 1;
}

int _findSpanStart(String sd, List<(String, int)> stack) {
  while (stack.isNotEmpty) {
    final (startSd, pos) = stack.removeLast();
    if (startSd == sd) return pos;
  }
  throw StateError('Unable to find opening span');
}

bool _isValidSpanStart(String line, int index) {
  if (index + 1 >= line.length) return false;
  if (_isWs(line[index + 1])) return false;
  if (index == 0) return true;
  final prev = line[index - 1];
  return _isWs(prev) || _spanDirs.contains(prev);
}

bool _isValidSpanEnd(String line, int index) {
  if (index == 0) return false;
  return !_isWs(line[index - 1]);
}

List<String> _splitKeepEnds(String text) {
  if (text.isEmpty) return const [];
  final out = <String>[];
  final buf = StringBuffer();
  for (var i = 0; i < text.length; i++) {
    buf.write(text[i]);
    if (text[i] == '\n') {
      out.add(buf.toString());
      buf.clear();
    }
  }
  if (buf.isNotEmpty) out.add(buf.toString());
  return out;
}
