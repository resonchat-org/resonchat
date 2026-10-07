// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';

/// Meta key for the user's language override.
///
/// Empty / absent means follow the device locale (English unless Chinese).
const prefLocaleKey = 'pref_locale';

/// Supported app locales. English is the fallback / default.
const supportedAppLocales = <Locale>[
  Locale('en'),
  Locale('zh'),
];

/// Resolves a stored preference value to a [Locale], or null for system.
Locale? localeFromPref(String? raw) {
  switch (raw) {
    case 'en':
      return const Locale('en');
    case 'zh':
    case 'zh_CN':
    case 'zh-CN':
      return const Locale('zh');
    default:
      return null;
  }
}

String prefFromLocale(Locale? locale) {
  if (locale == null) return '';
  if (locale.languageCode == 'zh') return 'zh';
  return 'en';
}

/// Explicit locale override, or null to follow the platform.
final localeOverrideProvider =
    StateNotifierProvider<LocaleOverrideNotifier, Locale?>((ref) {
  return LocaleOverrideNotifier(ref);
});

class LocaleOverrideNotifier extends StateNotifier<Locale?> {
  LocaleOverrideNotifier(this._ref) : super(null) {
    _load();
  }

  final Ref _ref;

  Future<void> _load() async {
    final raw = await _ref.read(databaseProvider).metaValue(prefLocaleKey);
    state = localeFromPref(raw);
  }

  Future<void> setOverride(Locale? locale) async {
    state = locale;
    final value = prefFromLocale(locale);
    if (value.isEmpty) {
      await _ref.read(databaseProvider).deleteMetaValue(prefLocaleKey);
    } else {
      await _ref.read(databaseProvider).setMetaValue(prefLocaleKey, value);
    }
  }
}
