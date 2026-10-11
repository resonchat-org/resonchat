// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';
import 'package:resonchat/ui/chat/quote_body.dart';

void main() {
  test('strips single-level quotes', () {
    final blocks = parseBodyBlocks('> hello\nworld');
    expect(blocks.length, 2);
    expect(blocks[0].quoteDepth, 1);
    expect(blocks[0].text, 'hello');
    expect(blocks[1].quoteDepth, 0);
    expect(blocks[1].text, 'world');
  });

  test('nests multi-level quotes', () {
    final blocks = parseBodyBlocks('>> deep\n> mid\nplain');
    expect(blocks.map((b) => (b.quoteDepth, b.text)).toList(), [
      (2, 'deep'),
      (1, 'mid'),
      (0, 'plain'),
    ]);
  });

  test('does not quote numeric greater-than', () {
    expect(isQuoteStart('>1 percent', 0), isFalse);
    expect(parseBodyBlocks('>1 percent').single.quoteDepth, 0);
  });

  test('does not quote emoticon >.<', () {
    expect(isQuoteStart('>.<', 0), isFalse);
  });

  test('accepts alt quote marker', () {
    final blocks = parseBodyBlocks('» quoted');
    expect(blocks.single.quoteDepth, 1);
    expect(blocks.single.text, 'quoted');
  });

  test('groups consecutive same-depth lines', () {
    final blocks = parseBodyBlocks('> a\n> b\nc');
    expect(blocks.length, 2);
    expect(blocks[0].text, 'a\nb');
    expect(blocks[0].quoteDepth, 1);
  });
}
