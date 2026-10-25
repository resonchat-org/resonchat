// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Linux-only: register the system colour emoji font with Flutter so emoji
// Text styles do not fall through fontconfig to Symbola / Noto Sans Symbols
// (monochrome or missing glyphs). Gajim/GTK get colour because Pango switches
// to the `emoji` family; Flutter does not, so we FontLoader the real TTF.
//
// Other platforms keep [emojiTextStyle]'s Apple / Segoe / Noto name list —
// those system families already work without loading a file.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show FontLoader;

/// Well-known install paths when `fc-match` is missing or unhelpful.
const List<String> kLinuxNotoColorEmojiPaths = <String>[
  '/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf',
  '/usr/share/fonts/noto/NotoColorEmoji.ttf',
  '/usr/share/fonts/truetype/noto-color-emoji/NotoColorEmoji.ttf',
  '/usr/share/fonts/noto-color-emoji/NotoColorEmoji.ttf',
  '/usr/share/fonts/TTF/NotoColorEmoji.ttf',
  '/usr/share/fonts/google-noto-color-emoji-fonts/NotoColorEmoji.ttf',
];

bool _loaded = false;

/// Registers system Noto Color Emoji on Linux when the package is installed.
///
/// No-op on other OSes, or when the font file cannot be found — [emojiTextStyle]
/// still names the family and other platforms' defaults still apply.
Future<void> ensureSystemColorEmojiFont() async {
  if (!Platform.isLinux || _loaded) return;

  final path = await resolveLinuxNotoColorEmojiPath();
  if (path == null) return;

  try {
    final bytes = await File(path).readAsBytes();
    if (bytes.isEmpty) return;
    final loader = FontLoader('Noto Color Emoji');
    loader.addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
    await loader.load();
    _loaded = true;
  } on Object {
    // Unreadable file or engine rejection — leave name-based fallback.
  }
}

/// Absolute path to a colour emoji TTF, or `null` if the system has none.
///
/// Prefers `fc-match` (same resolver GTK uses), then [kLinuxNotoColorEmojiPaths].
Future<String?> resolveLinuxNotoColorEmojiPath() async {
  final fromFc = await _fcMatchNotoColorEmojiFile();
  if (fromFc != null) return fromFc;
  for (final path in kLinuxNotoColorEmojiPaths) {
    if (await File(path).exists()) return path;
  }
  return null;
}

Future<String?> _fcMatchNotoColorEmojiFile() async {
  try {
    final result = await Process.run('fc-match', [
      '-f',
      '%{file}',
      'Noto Color Emoji',
    ]);
    if (result.exitCode != 0) return null;
    final path = (result.stdout as String).trim();
    if (path.isEmpty || !path.startsWith('/')) return null;
    // Require the colour face — fc-match can return Symbola if Noto is absent.
    final lower = path.toLowerCase();
    if (!lower.contains('color') || !lower.contains('emoji')) return null;
    if (!await File(path).exists()) return null;
    return path;
  } on Object {
    return null;
  }
}
