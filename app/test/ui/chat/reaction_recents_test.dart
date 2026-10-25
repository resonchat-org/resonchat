// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';

import 'package:resonchat/ui/chat/reaction_recents.dart';
import 'package:resonchat/xmpp/chat/reactions.dart';

void main() {
  group('promoteQuickReaction', () {
    test('a palette emoji takes the first slot and the row stays full', () {
      final updated = promoteQuickReaction(kQuickReactions, '🎉');

      expect(updated.first, '🎉');
      expect(updated, hasLength(kQuickReactionSlots));
      // The tail of the default row falls off; the promoted emoji appears once.
      expect(updated, contains('👍'));
      expect(updated, isNot(contains('🙏')));
      expect(updated.where((emoji) => emoji == '🎉'), hasLength(1));
    });

    test('an emoji already on the row moves instead of duplicating', () {
      final updated = promoteQuickReaction(kQuickReactions, '🙏');

      expect(updated.first, '🙏');
      expect(updated, hasLength(kQuickReactionSlots));
      expect(updated.where((emoji) => emoji == '🙏'), hasLength(1));
    });

    test('a text-presentation value is refused', () {
      // `❤` (U+2764) is one code point but Linux draws it black beside the
      // coloured emoji, so it must not reach the front row from prefs either.
      expect(promoteQuickReaction(kQuickReactions, '❤'), kQuickReactions);
    });

    test('a multi-code-point value is refused', () {
      // The palette and prefs may only ever hold single code points; a
      // variation selector would render differently on the other side.
      expect(promoteQuickReaction(kQuickReactions, '❤️'), kQuickReactions);
    });
  });

  test('without opened prefs the defaults are still a valid row', () async {
    // Unit tests do not install appPrefs; the loader must not throw.
    expect(await loadQuickReactions(), kQuickReactions);
    await saveQuickReactions(kQuickReactions);
  });

  test(
    'every default menu emoji is one code point and coloured by default',
    () {
      for (final emoji in kQuickReactions) {
        expect(emoji.runes, hasLength(1), reason: emoji);
      }
      // U+2764 is text-presentation by default; Linux draws it as a black glyph
      // beside the coloured ones.
      expect(kQuickReactions, isNot(contains('❤')));
    },
  );
}
