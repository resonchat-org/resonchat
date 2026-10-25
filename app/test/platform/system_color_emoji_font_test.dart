// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:resonchat/platform/system_color_emoji_font_io.dart';

void main() {
  test(
    'resolveLinuxNotoColorEmojiPath finds the system colour face on Linux',
    () async {
      if (!Platform.isLinux) return;
      final path = await resolveLinuxNotoColorEmojiPath();
      // CI / desktops with fonts-noto-color-emoji should resolve; without the
      // package this is null and emojiTextStyle falls back to the family name.
      if (path == null) return;
      expect(File(path).existsSync(), isTrue);
      expect(path.toLowerCase(), contains('color'));
      expect(path.toLowerCase(), contains('emoji'));
    },
  );

  test('ensureSystemColorEmojiFont is safe when the font is missing', () async {
    // Must not throw even if resolve returns null (covered by the no-op path).
    await ensureSystemColorEmojiFont();
  });
}
