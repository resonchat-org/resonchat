// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The emoji catalogue.
//
// The register here is data correctness, because unlike a rendering bug a bad
// character in this file is shipped to every user of every build and nobody
// notices it: the panel draws a box, the box is small, and the user just does
// not use that tab. So the tests are about the *characters* and about the two
// lists staying genuinely different from each other.

import 'package:test/test.dart';

import 'package:resonchat/ui/chat/emoji_data.dart';

void main() {
  group('every tab has something in it', () {
    test('no category is empty', () {
      // A tab with nothing under it is a tab that reads as a bug report.
      for (final category in EmojiCategory.values) {
        expect(emojiIn(category), isNotEmpty, reason: category.name);
      }
    });

    test('the tabs are captioned, and none twice', () {
      final labels = EmojiCategory.values.map((c) => c.label).toList();
      for (final label in labels) {
        expect(label, isNotEmpty);
      }
      expect(labels.toSet(), hasLength(labels.length));
    });
  });

  group('every character is one the standard defines', () {
    test('no category holds an unrenderable entry', () {
      // The two-boxes question, asked of the data rather than of a widget: text
      // and stray code points in an emoji list are what a hand edit or a
      // generator leaves behind.
      for (final category in EmojiCategory.values) {
        expect(unrenderableIn(category), isEmpty, reason: category.name);
        expect(isCategoryRenderable(category), isTrue, reason: category.name);
      }
    });

    test('every entry in the flat list renders too', () {
      for (final entry in allEmoji) {
        expect(isRenderableEmoji(entry.emoji), isTrue, reason: entry.name);
      }
    });

    test('text is not an emoji', () {
      expect(isRenderableEmoji('a'), isFalse);
      expect(isRenderableEmoji('7'), isFalse);
      expect(isRenderableEmoji('!'), isFalse);
    });

    test('a joiner or a variation selector alone is not an emoji either', () {
      // Both are legal Unicode and neither has a glyph, which is why the string
      // made only of them is two empty boxes rather than one emoji.
      expect(isRenderableEmoji('\u{200D}'), isFalse);
      expect(isRenderableEmoji('\u{FE0F}'), isFalse);
      expect(isRenderableEmoji('\u{200D}\u{FE0F}'), isFalse);
    });

    test('an empty string is not an emoji', () {
      expect(isRenderableEmoji(''), isFalse);
    });
  });

  group('what may be a reaction', () {
    test('every catalogue entry qualifies as a reaction', () {
      for (final entry in allEmoji) {
        expect(isReactionEmoji(entry.emoji), isTrue, reason: entry.name);
      }
    });

    test('the heart strips FE0F and both forms are reactions', () {
      expect(isRenderableEmoji('❤️'), isTrue);
      expect(isReactionEmoji('❤️'), isTrue);
      expect(stripEmojiPresentationSelectors('❤️'), '❤');
      expect(isRenderableEmoji('❤'), isTrue);
      expect(isReactionEmoji('❤'), isTrue);
    });

    test('a skin tone, a flag, and a ZWJ sequence are reactions', () {
      expect(isReactionEmoji('\u{1F44D}\u{1F3FB}'), isTrue);
      expect(isReactionEmoji('🇩🇪'), isTrue);
      expect(isReactionEmoji('\u{1F9D1}\u{200D}\u{1F4BB}'), isTrue);
    });

    test('kaomoji and plain text are not reactions', () {
      expect(isReactionEmoji('(＾▽＾)'), isFalse);
      expect(isReactionEmoji('test'), isFalse);
      expect(isReactionEmoji(''), isFalse);
    });
  });

  group('the recent tab', () {
    test('every entry is a valid reaction', () {
      for (final entry in emojiIn(EmojiCategory.recent)) {
        expect(isReactionEmoji(entry.emoji), isTrue, reason: entry.name);
      }
    });

    test('every entry is in the catalogue too', () {
      // The seed is a view over entries that exist elsewhere. A recent entry
      // that is not in `allEmoji` is one the search cannot find, so tapping it
      // inserts a character the user could not have picked by name.
      final catalogued = allEmoji.map((e) => e.emoji).toSet();
      for (final entry in emojiIn(EmojiCategory.recent)) {
        expect(catalogued, contains(entry.emoji), reason: entry.name);
      }
    });
  });

  group('the flat list', () {
    test('nothing appears twice', () {
      // A duplicate draws twice in the flat list and lands twice in the
      // search results, which reads as the panel repeating itself.
      final characters = allEmoji.map((e) => e.emoji);
      expect(characters.toSet(), hasLength(characters.length));
    });

    test('nor does any name', () {
      final names = allEmoji.map((e) => e.name);
      expect(names.toSet(), hasLength(names.length));
    });

    test('order is category order, then catalogue order', () {
      // Determinism is the point: results that reorder between two keystrokes
      // read as a broken panel, so the order is a property of this file rather
      // than of a hash, a counter or a frequency ranking.
      final expected = <String>[
        for (final category in EmojiCategory.values)
          if (category != EmojiCategory.recent)
            ...emojiIn(category).map((e) => e.emoji),
      ];
      expect(allEmoji.map((e) => e.emoji), expected);
      // Identity too: it is a top-level final precisely so a panel that
      // compares the list by `identical` on every rebuild can do so.
      expect(identical(allEmoji, allEmoji), isTrue);
    });

    test('every name is lower-case words a keyboard can type', () {
      // The search box is a Latin keyboard, and a name with a digit or a
      // capital in it is a name a query can never equal.
      for (final entry in allEmoji) {
        expect(entry.name, isNotEmpty, reason: entry.emoji);
        expect(
          RegExp(r'^[a-z]+( [a-z]+)*$').hasMatch(entry.name),
          isTrue,
          reason: entry.emoji,
        );
      }
    });

    test('and it cannot be mutated by a widget', () {
      expect(() => allEmoji.add(allEmoji.first), throwsUnsupportedError);
    });
  });

  group('search finds things', () {
    test('it is case-insensitive', () {
      expect(searchEmoji('THUMBS UP').map((e) => e.emoji), ['👍']);
      expect(searchEmoji('Thumbs Up').map((e) => e.emoji), ['👍']);
      expect(searchEmoji('thumbs up').map((e) => e.emoji), ['👍']);
    });

    test('a whole word reaches an entry that does not start with it', () {
      expect(searchEmoji('heart').map((e) => e.emoji), contains('❤️'));
      expect(searchEmoji('tear').map((e) => e.emoji), ['😂']);
    });

    test('the exact name outranks a word inside another name', () {
      // `heart` is `❤`'s whole name and only a word of `red heart`, so the
      // shorter name ranks first.
      expect(searchEmoji('heart').first.emoji, '❤');
      expect(searchEmoji('red heart').map((e) => e.emoji), ['❤️']);
    });

    test('results only ever come out of the flat list', () {
      final catalogued = allEmoji.map((e) => e.emoji).toSet();
      for (final entry in searchEmoji('a')) {
        expect(catalogued, contains(entry.emoji), reason: entry.name);
      }
    });

    test('results never repeat', () {
      final characters = searchEmoji('a').map((e) => e.emoji);
      expect(characters.toSet(), hasLength(characters.length));
    });

    test('one more character narrows the list', () {
      // The ranking keeps every rung below it reachable, so typing narrows
      // instead of reshuffling what is already on screen.
      final wide = searchEmoji('thumbs').map((e) => e.emoji).toSet();
      for (final entry in searchEmoji('thumbs up')) {
        expect(wide, contains(entry.emoji));
      }
    });
  });

  group('search does not invent results', () {
    test('a nonsense query finds nothing', () {
      // Returning the whole catalogue for a query that matches nothing is how a
      // user decides search is broken.
      expect(searchEmoji('zzzqqq'), isEmpty);
      expect(searchEmoji('qwertyuiopzz'), isEmpty);
    });

    test('and neither does a blank one', () {
      expect(searchEmoji(''), isEmpty);
      expect(searchEmoji('   '), isEmpty);
      expect(searchEmoji('\t\n '), isEmpty);
    });
  });

  group('search stays bounded', () {
    test('a one-letter query does not return the catalogue', () {
      expect(searchEmoji('a').length, lessThanOrEqualTo(kSearchLimit));
      expect(searchEmoji('e').length, lessThanOrEqualTo(kSearchLimit));
    });

    test('an explicit limit is the head of the full result', () {
      final all = searchEmoji('a');
      expect(all.length, greaterThan(3));
      expect(
        searchEmoji('a', limit: 3).map((e) => e.emoji),
        all.take(3).map((e) => e.emoji),
      );
    });

    test('a limit of nothing returns nothing', () {
      expect(searchEmoji('a', limit: 0), isEmpty);
    });
  });

  group('search order does not move', () {
    test('two calls agree', () {
      // Otherwise the grid reshuffles on every rebuild, which reads as the
      // emoji flickering rather than as the list being sorted.
      for (final query in ['heart', 'a', 'flag', 'thumbs up', 'e']) {
        final first = searchEmoji(query).map((e) => e.emoji).toList();
        final second = searchEmoji(query).map((e) => e.emoji).toList();
        expect(first, second, reason: query);
      }
    });

    test('and an interleaved query does not disturb it', () {
      // Search is a pure function of one string: a user typing `a`, then `ab`,
      // then back to `a` must see the same grid both times, whatever happened
      // in between.
      final before = searchEmoji('heart').map((e) => e.emoji).toList();
      searchEmoji('flag');
      searchEmoji('nonsense query');
      expect(searchEmoji('heart').map((e) => e.emoji), before);
    });
  });
}
