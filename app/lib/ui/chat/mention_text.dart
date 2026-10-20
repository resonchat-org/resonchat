// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Bold nick spans in a group message body (Conversations MessageAdapter).

import 'package:flutter/painting.dart';

import 'package:resonchat/xmpp/notify_policy.dart';

/// Builds a [TextSpan] that bolds every nick highlight in [text].
///
/// Matching uses [nickHighlightPattern] so paint and notification agree.
InlineSpan mentionAwareSpan(
  String text, {
  required TextStyle style,
  required Iterable<String> highlightNicks,
  TextStyle? mentionStyle,
}) {
  final names = highlightNicks.where((n) => n.trim().isNotEmpty).toList();
  if (names.isEmpty || text.isEmpty) {
    return TextSpan(text: text, style: style);
  }

  final hits = <({int start, int end})>[];
  for (final name in names) {
    for (final m in nickHighlightPattern(name).allMatches(text)) {
      hits.add((start: m.start, end: m.end));
    }
  }
  if (hits.isEmpty) return TextSpan(text: text, style: style);

  hits.sort((a, b) => a.start.compareTo(b.start));
  final merged = <({int start, int end})>[];
  for (final h in hits) {
    if (merged.isEmpty || h.start > merged.last.end) {
      merged.add(h);
    } else if (h.end > merged.last.end) {
      merged[merged.length - 1] = (start: merged.last.start, end: h.end);
    }
  }

  final bold = mentionStyle ?? style.copyWith(fontWeight: FontWeight.w700);
  final children = <InlineSpan>[];
  var cursor = 0;
  for (final h in merged) {
    if (h.start > cursor) {
      children.add(
        TextSpan(text: text.substring(cursor, h.start), style: style),
      );
    }
    children.add(TextSpan(text: text.substring(h.start, h.end), style: bold));
    cursor = h.end;
  }
  if (cursor < text.length) {
    children.add(TextSpan(text: text.substring(cursor), style: style));
  }
  return TextSpan(style: style, children: children);
}
