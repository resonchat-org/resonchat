// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonchat/ui/chat/im_style.dart';

void main() {
  test('parses bold italic strike and code', () {
    final styles = parseImStyles('see *bold* and _italic_ ~strike~ and `code`');
    expect(styles.map((s) => s.keyword).toList(), ['*', '_', '~', '`']);
    final bold = styles.firstWhere((s) => s.keyword == '*');
    expect(
      'see *bold* and _italic_ ~strike~ and `code`'.substring(
        bold.contentStart,
        bold.contentEnd,
      ),
      'bold',
    );
  });

  test('parses nested bold+italic', () {
    final styles = parseImStyles('*_both_*');
    expect(styles.length, 2);
    expect(styles[0].keyword, '*');
    expect(styles[1].keyword, '_');
  });

  test('parses triple-backtick blocks across newlines', () {
    final styles = parseImStyles('before\n```\nline\n```\nafter');
    expect(styles.length, 1);
    expect(styles.single.keyword, '```');
  });

  test('ignores unmatched markers', () {
    expect(parseImStyles('just *one'), isEmpty);
    expect(parseImStyles('* spaced *'), isEmpty);
  });

  test('imStyleForKeyword maps Conversations spans', () {
    const base = TextStyle(fontSize: 14);
    expect(imStyleForKeyword('*', base).fontWeight, FontWeight.w700);
    expect(imStyleForKeyword('_', base).fontStyle, FontStyle.italic);
    expect(imStyleForKeyword('~', base).decoration, TextDecoration.lineThrough);
    expect(imStyleForKeyword('`', base).fontFamily, 'monospace');
    expect(imStyleForKeyword('```', base).fontFamily, 'monospace');
  });
}
