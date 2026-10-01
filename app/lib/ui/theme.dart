// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Design tokens. Starting values only — sample precisely from the
// Telegram Android sources before pixel-polishing (docs/05 §2).
// Brand assets are our own; nothing here uses Telegram trademarks.

import 'package:flutter/material.dart';

class AppThemeTokens {
  const AppThemeTokens._();

  static const double avatarList = 54;
  static const double avatarChat = 40;
  static const double bubbleRadius = 12;
  static const double messageFontSize = 16;

  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF419FD9));
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.primary,
        foregroundColor: Colors.white,
      ),
    );
  }

  static ThemeData dark() {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF5EB5F7),
      brightness: Brightness.dark,
    );
    return ThemeData(useMaterial3: true, colorScheme: scheme);
  }
}

/// Small lock badge used in app bars: `OMEMO`, `PQ`, or plaintext.
class EncBadge extends StatelessWidget {
  const EncBadge({super.key, required this.label, required this.locked});

  final String label;
  final bool locked;

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: Icon(
        locked ? Icons.lock : Icons.lock_open,
        size: 14,
      ),
      label: Text(label),
      visualDensity: VisualDensity.compact,
    );
  }
}
