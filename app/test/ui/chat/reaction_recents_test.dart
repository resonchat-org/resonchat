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

    test('a text-presentation heart is refused', () {
      // `❤` (U+2764) Linux draws black beside the coloured emoji.
      expect(promoteQuickReaction(kQuickReactions, '❤'), kQuickReactions);
    });

    test('a heart with FE0F strips to the black heart and is refused', () {
      expect(promoteQuickReaction(kQuickReactions, '❤️'), kQuickReactions);
    });

    test('a flag (multi-code-point) is accepted', () {
      // Gajim allows regional-indicator pairs as reactions.
      final updated = promoteQuickReaction(kQuickReactions, '🇩🇪');
      expect(updated.first, '🇩🇪');
      expect(updated, hasLength(kQuickReactionSlots));
    });
  });

  test('without opened prefs the defaults are still a valid row', () async {
    // Unit tests do not install appPrefs; the loader must not throw.
    expect(await loadQuickReactions(), kQuickReactions);
    await saveQuickReactions(kQuickReactions);
  });

  test('every default menu emoji has emoji presentation by default', () {
    // U+2764 is text-presentation by default; Linux draws it as a black glyph
    // beside the coloured ones.
    expect(kQuickReactions, isNot(contains('❤')));
  });
}
