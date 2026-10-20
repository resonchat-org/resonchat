// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/painting.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:resonchat/ui/chat/mention_text.dart';

void main() {
  const base = TextStyle(fontSize: 14);
  const bold = TextStyle(fontSize: 14, fontWeight: FontWeight.w700);

  test('bolds a nick highlight and leaves the rest plain', () {
    final span = mentionAwareSpan(
      'hey Alice, see this',
      style: base,
      highlightNicks: const ['Alice'],
      mentionStyle: bold,
    ) as TextSpan;
    expect(span.children, isNotNull);
    final texts = span.children!
        .whereType<TextSpan>()
        .map((s) => (s.text, s.style?.fontWeight))
        .toList();
    expect(texts, [
      ('hey ', null),
      ('Alice', FontWeight.w700),
      (', see this', null),
    ]);
  });

  test('no nick match stays a single plain span', () {
    final span = mentionAwareSpan(
      'hello there',
      style: base,
      highlightNicks: const ['Alice'],
      mentionStyle: bold,
    ) as TextSpan;
    expect(span.children, isNull);
    expect(span.text, 'hello there');
  });
}
