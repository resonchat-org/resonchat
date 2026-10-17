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
import 'package:resonchat/utils/emoji_data.dart';

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

  group('what may be sent', () {
    test('every sendable entry is exactly one code point', () {
      // The rule kQuickReactions already applies to six characters, extended to
      // the whole catalogue: a reaction is drawn by somebody else's client, and
      // a sequence — a variation selector, a skin tone, a ZWJ join — is exactly
      // how two clients end up drawing different pictures for it.
      for (final entry in sendableEmoji) {
        expect(entry.emoji.runes.length, 1, reason: entry.name);
        expect(isSendableEmoji(entry.emoji), isTrue, reason: entry.name);
      }
    });

    test('the sendable set is a subset of the displayable one', () {
      final displayable = allEmoji.map((e) => e.emoji).toSet();
      expect(
        sendableEmoji.map((e) => e.emoji).toSet(),
        everyElement(isIn(displayable)),
      );
    });

    test('the two lists partition the catalogue, and neither is empty', () {
      // An empty `displayOnlyEmoji` would mean the two questions had collapsed
      // into one, and the file would have stopped saying anything at all.
      expect(sendableEmoji, isNotEmpty);
      expect(displayOnlyEmoji, isNotEmpty);
      expect(sendableEmoji.length + displayOnlyEmoji.length, allEmoji.length);
    });

    test('the heart is the trap, in both directions', () {
      // `❤️` is U+2764 U+FE0F. Two code points, so it is fine in the panel and
      // not fine as a reaction — which is why kQuickReactions offers `❤`.
      expect(isRenderableEmoji('❤️'), isTrue);
      expect(isSendableEmoji('❤️'), isFalse);
      expect(isRenderableEmoji('❤'), isTrue);
      expect(isSendableEmoji('❤'), isTrue);
      expect(sendableEmoji.map((e) => e.emoji), contains('❤'));
      expect(sendableEmoji.map((e) => e.emoji), isNot(contains('❤️')));
    });

    test('a skin tone and a flag are displayable, not sendable', () {
      // A flag is two regional indicators and renders only where a flag font
      // exists; a skin tone is two code points whose application depends on the
      // receiver. Both look right here, which is the trap.
      expect(isRenderableEmoji('\u{1F44D}\u{1F3FB}'), isTrue);
      expect(isSendableEmoji('\u{1F44D}\u{1F3FB}'), isFalse);
      expect(isRenderableEmoji('🇩🇪'), isTrue);
      expect(isSendableEmoji('🇩🇪'), isFalse);
      expect(isRenderableEmoji('\u{1F9D1}\u{200D}\u{1F4BB}'), isTrue);
      expect(isSendableEmoji('\u{1F9D1}\u{200D}\u{1F4BB}'), isFalse);
    });

    test('only the categories without sequences are sendable throughout', () {
      // Pinned because it is the whole distinction: recent and smileys happen
      // to hold single code points only, and a reaction picker must read from
      // `sendableEmoji` rather than from a category.
      final sendableCategories = EmojiCategory.values.where(isCategorySendable);
      expect(sendableCategories, [EmojiCategory.recent, EmojiCategory.smileys]);
    });
  });

  group('the recent tab', () {
    test('every entry is safe to send', () {
      // It is what a first-run user reaches for, so it has to hold to the same
      // rule as a reaction rather than to the rule for the panel.
      for (final entry in emojiIn(EmojiCategory.recent)) {
        expect(isSendableEmoji(entry.emoji), isTrue, reason: entry.name);
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
      // sendable one leads the list the user is looking at.
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
