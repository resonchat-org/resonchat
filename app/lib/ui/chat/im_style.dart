// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Conversations `ImStyleParser` + `StylingHelper` style spans:
// `*bold*` `_italic_` `~strike~` `` `code` `` / ```block```.

import 'package:flutter/painting.dart';

/// One IM-style span (inclusive [end] index of the closing keyword char).
class ImStyle {
  const ImStyle({
    required this.keyword,
    required this.start,
    required this.end,
  });

  /// `*`, `_`, `~`, `` ` ``, or ``` ```.
  final String keyword;
  final int start;
  final int end;

  int get keywordLength => keyword.length;

  /// Content between keywords (start inclusive, end exclusive).
  int get contentStart => start + keywordLength;
  int get contentEnd => end - keywordLength + 1;

  /// Marker ranges as half-open [start, end) pairs.
  List<(int, int)> get keywordRanges => [
    (start, start + keywordLength),
    (contentEnd, end + 1),
  ];
}

/// Conversations `StylingHelper.transformColor` — keywords at 45% opacity.
Color imKeywordColor(Color textColor) =>
    textColor.withValues(alpha: textColor.a * 0.45);

const _keywords = {'*', '_', '~', '`'};
const _noSubParse = {'`'};
const _blockKeywords = {'`'};

/// Conversations `ImStyleParser.parse`.
List<ImStyle> parseImStyles(String text, [int start = 0, int? end]) {
  final last = end ?? (text.isEmpty ? -1 : text.length - 1);
  if (text.isEmpty || start > last) return const [];
  final styles = <ImStyle>[];
  for (var i = start; i <= last; i++) {
    final c = text[i];
    if (!_keywords.contains(c)) continue;
    if (!_precededByWhiteSpace(text, i, start)) continue;
    if (_followedByWhitespace(text, i, last)) continue;

    if (_blockKeywords.contains(c) &&
        _isCharRepeatedTwoTimes(text, c, i + 1, last)) {
      final to = _seekEndBlock(text, c, i + 3, last);
      if (to != -1 && to != i + 5) {
        styles.add(ImStyle(keyword: '$c$c$c', start: i, end: to));
        i = to;
        continue;
      }
    }

    final to = _seekEnd(text, c, i + 1, last);
    if (to != -1 && to != i + 1) {
      styles.add(ImStyle(keyword: c, start: i, end: to));
      if (!_noSubParse.contains(c)) {
        styles.addAll(parseImStyles(text, i + 1, to - 1));
      }
      i = to;
    }
  }
  return styles;
}

bool _isCharRepeatedTwoTimes(String text, String c, int index, int end) =>
    index + 1 <= end && text[index] == c && text[index + 1] == c;

bool _precededByWhiteSpace(String text, int index, int start) =>
    index == start || _isWhitespace(text[index - 1]);

bool _followedByWhitespace(String text, int index, int end) =>
    index >= end || _isWhitespace(text[index + 1]);

bool _isWhitespace(String ch) => ch.trim().isEmpty;

int _seekEnd(String text, String needle, int start, int end) {
  for (var i = start; i <= end; i++) {
    final c = text[i];
    if (c == needle && !_isWhitespace(text[i - 1])) {
      if (_followedByWhitespace(text, i, end)) {
        return i;
      }
      final higher = _seekHigherOrderEndWithoutNewBeginning(
        text,
        needle,
        i + 1,
        end,
      );
      if (higher != -1) return higher;
      return i;
    } else if (c == '\n') {
      return -1;
    }
  }
  return -1;
}

int _seekHigherOrderEndWithoutNewBeginning(
  String text,
  String needle,
  int start,
  int end,
) {
  for (var i = start; i <= end; i++) {
    final c = text[i];
    if (c == needle &&
        _precededByWhiteSpace(text, i, start) &&
        !_followedByWhitespace(text, i, end)) {
      return -1;
    } else if (c == needle &&
        !_isWhitespace(text[i - 1]) &&
        _followedByWhitespace(text, i, end)) {
      return i;
    } else if (c == '\n') {
      return -1;
    }
  }
  return -1;
}

int _seekEndBlock(String text, String needle, int start, int end) {
  for (var i = start; i <= end; i++) {
    if (text[i] == needle &&
        _isCharRepeatedTwoTimes(text, needle, i + 1, end)) {
      return i + 2;
    }
  }
  return -1;
}

/// TextStyle modifiers for an [ImStyle.keyword] (Conversations `createSpanForStyle`).
TextStyle imStyleForKeyword(String keyword, TextStyle base) {
  switch (keyword) {
    case '*':
      return base.copyWith(fontWeight: FontWeight.w700);
    case '_':
      return base.copyWith(fontStyle: FontStyle.italic);
    case '~':
      return base.copyWith(decoration: TextDecoration.lineThrough);
    case '`':
    case '```':
      return base.copyWith(
        fontFamily: 'monospace',
        fontFamilyFallback: const [
          'Courier',
          'Courier New',
          'Menlo',
          'Monaco',
          'Consolas',
        ],
      );
    default:
      return base;
  }
}
