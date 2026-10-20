// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Gajim-aligned message styling (blocks / spans / URIs).

import 'package:flutter_test/flutter_test.dart';

import 'package:resonchat/ui/chat/emoji_body.dart';
import 'package:resonchat/ui/chat/message_styling.dart';

void main() {
  group('spans', () {
    test('parses strong emph strike and pre', () {
      final r = processMessageStyling('*strong* _emph_~strike~  `pre`');
      expect(r.blocks, hasLength(1));
      final plain = r.blocks.single as PlainBlock;
      expect(plain.spans.map((s) => s.kind).toList(), [
        StyleKind.strong,
        StyleKind.emphasis,
        StyleKind.strike,
        StyleKind.pre,
      ]);
    });

    test('spans lazily match', () {
      final r = processMessageStyling('*strong*plain*');
      final plain = r.blocks.single as PlainBlock;
      expect(plain.spans, hasLength(1));
      expect(
        plain.text.substring(plain.spans.single.start, plain.spans.single.end),
        '*strong*',
      );
    });

    test('nested spans', () {
      final r = processMessageStyling('_*~children~*_');
      final plain = r.blocks.single as PlainBlock;
      expect(plain.spans.map((s) => s.kind).toSet(), {
        StyleKind.emphasis,
        StyleKind.strong,
        StyleKind.strike,
      });
    });

    test('pre cannot have children', () {
      final r = processMessageStyling('_no pre `with *children*`_');
      final plain = r.blocks.single as PlainBlock;
      expect(plain.spans.any((s) => s.kind == StyleKind.pre), isTrue);
      // Inner *children* is inside pre — no strong span for it.
      expect(plain.spans.where((s) => s.kind == StyleKind.strong), isEmpty);
    });
  });

  group('blocks', () {
    test('splits fenced pre from following plain', () {
      final r = processMessageStyling('```\npre\n```\n*plain*');
      expect(r.blocks[0], isA<PreBlock>());
      expect(r.blocks[1], isA<PlainBlock>());
      final pre = r.blocks[0] as PreBlock;
      expect(pre.prepared.code, 'pre');
      final plain = r.blocks[1] as PlainBlock;
      expect(plain.spans.single.kind, StyleKind.strong);
    });

    test('pre with language tag', () {
      final r = processMessageStyling('```dart\nvoid main() {}\n```');
      final pre = r.blocks.single as PreBlock;
      expect(pre.prepared.language, 'dart');
      expect(pre.prepared.code, 'void main() {}');
    });

    test('quote nests and unquotes', () {
      final r = processMessageStyling('> hello\nworld');
      expect(r.blocks[0], isA<QuoteBlock>());
      expect(r.blocks[1], isA<PlainBlock>());
      final q = r.blocks[0] as QuoteBlock;
      expect(q.unquote().trim(), 'hello');
      expect(q.blocks.single, isA<PlainBlock>());
    });

    test('nested quotes', () {
      final r = processMessageStyling('>> deep\n> mid');
      final outer = r.blocks.whereType<QuoteBlock>().first;
      expect(outer.blocks.whereType<QuoteBlock>(), isNotEmpty);
    });

    test('accepts alt quote marker', () {
      final r = processMessageStyling('» quoted');
      expect(r.blocks.single, isA<QuoteBlock>());
    });
  });

  group('uris', () {
    test('linkifies https and bare jid', () {
      final uris = processUris('see https://example.org and user@example.org');
      expect(uris.map((u) => u.url).toList(), [
        'https://example.org',
        'xmpp:user@example.org',
      ]);
    });

    test('trims trailing comma', () {
      final uris = processUris('https://example.org,');
      expect(uris.single.url, 'https://example.org');
    });
  });

  group('emoji', () {
    test('detects emoji-only messages', () {
      expect(isEmojiOnlyMessage('👍'), isTrue);
      expect(isEmojiOnlyMessage('😀🎉'), isTrue);
      expect(isEmojiOnlyMessage('hi 👍'), isFalse);
      expect(emojiOnlyScale('👍'), greaterThan(emojiOnlyScale('😀🎉')));
    });
  });
}
