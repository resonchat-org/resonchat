// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Theme colour: Material You (dynamic) or a fixed accent.
//
// TelegramAndroid (Nekogram MonetHelper) maps Monet Light/Dark themes from
// Android 12+ `system_accent*` / `system_neutral*` resources. Conversations
// uses Material Components `DynamicColors`. Here we use the Flutter
// `dynamic_color` package (same wallpaper / system accent source on Android
// S+, plus platform accents on Linux/macOS/Windows).

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../store/prefs_database.dart';
import 'theme.dart';

const prefAccentKey = 'pref_accent_color';

/// Stored as `dynamic` for Material You, otherwise a fixed [AccentColor.stored].
class AccentPreference {
  const AccentPreference.dynamic()
    : useDynamic = true,
      fixed = AccentColor.blue;

  const AccentPreference.fixed(this.fixed) : useDynamic = false;

  final bool useDynamic;
  final AccentColor fixed;

  String get stored => useDynamic ? 'dynamic' : fixed.stored;

  static AccentPreference fromStored(String? raw) {
    if (raw == 'dynamic') return const AccentPreference.dynamic();
    return AccentPreference.fixed(AccentColor.fromStored(raw));
  }
}

/// Named fixed accents (used when Material You is off).
enum AccentColor {
  blue(stored: 'blue', bar: Color(0xFF517DA2), accent: Color(0xFF3D9BD4)),
  teal(stored: 'teal', bar: Color(0xFF2A9D8F), accent: Color(0xFF2EC4B6)),
  green(stored: 'green', bar: Color(0xFF3D8B5F), accent: Color(0xFF4FAE4E)),
  amber(stored: 'amber', bar: Color(0xFFB07D2A), accent: Color(0xFFE0A100)),
  orange(stored: 'orange', bar: Color(0xFFC26A2D), accent: Color(0xFFE67E22)),
  rose(stored: 'rose', bar: Color(0xFFB04A5A), accent: Color(0xFFE05A6C)),
  violet(stored: 'violet', bar: Color(0xFF6B5B95), accent: Color(0xFF8E7CC3)),
  slate(stored: 'slate', bar: Color(0xFF4A5568), accent: Color(0xFF718096));

  const AccentColor({
    required this.stored,
    required this.bar,
    required this.accent,
  });

  final String stored;
  final Color bar;
  final Color accent;

  Color get swatch => bar;

  static AccentColor fromStored(String? raw) {
    for (final v in AccentColor.values) {
      if (v.stored == raw) return v;
    }
    return AccentColor.blue;
  }

  TgColors tgColors(Brightness brightness) {
    final base = brightness == Brightness.dark
        ? const TgColors.dark()
        : const TgColors.light();
    if (brightness == Brightness.light) {
      return base.copyWith(barBackground: bar, accent: accent);
    }
    return base.copyWith(
      barBackground: Color.lerp(bar, const Color(0xFF17212B), 0.45)!,
      accent: Color.lerp(accent, Colors.white, 0.12)!,
    );
  }
}

/// Builds [ThemeData] for the current accent preference.
ThemeData themeForAccent({
  required AccentPreference preference,
  required Brightness brightness,
  ColorScheme? dynamicScheme,
}) {
  if (preference.useDynamic && dynamicScheme != null) {
    return AppThemeTokens.fromMaterialYou(dynamicScheme.harmonized());
  }
  // Dynamic requested but unavailable on this platform / OS version.
  if (preference.useDynamic) {
    return AppThemeTokens.fromSeed(preference.fixed.accent, brightness);
  }
  return AppThemeTokens.lightOrDark(
    preference.fixed.tgColors(brightness),
    brightness,
  );
}

final accentPreferenceProvider =
    StateNotifierProvider<AccentPreferenceNotifier, AccentPreference>((ref) {
      return AccentPreferenceNotifier();
    });

class AccentPreferenceNotifier extends StateNotifier<AccentPreference> {
  AccentPreferenceNotifier() : super(const AccentPreference.dynamic()) {
    _load();
  }

  Future<void> _load() async {
    final raw = await appPrefs.getString(prefAccentKey);
    // First launch / unset: Material You when we can probe later; default
    // stored value stays dynamic. Existing installs with a fixed colour keep it.
    if (raw == null || raw.isEmpty) {
      state = const AccentPreference.dynamic();
      return;
    }
    state = AccentPreference.fromStored(raw);
  }

  Future<void> setPreference(AccentPreference preference) async {
    state = preference;
    await appPrefs.setString(prefAccentKey, preference.stored);
  }
}
