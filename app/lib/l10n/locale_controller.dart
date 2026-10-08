// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../account/account_hub.dart';
import '../state/providers.dart';

/// Meta key for the user's language override.
///
/// Empty / absent means follow the device locale (English unless Chinese).
const prefLocaleKey = 'pref_locale';

/// Supported app locales. English is the fallback / default.
const supportedAppLocales = <Locale>[Locale('en'), Locale('zh')];

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
    // Watch hub so first login (no DB at cold start) reloads prefs later.
    _ref.listen<AccountHub>(accountHubProvider, (_, _) {
      _load();
    });
    _load();
  }

  final Ref _ref;

  Future<void> _load() async {
    // First-run login has no session yet — stay on system locale.
    final db = accountHub.primaryDbOrNull;
    if (db == null) return;
    final raw = await db.metaValue(prefLocaleKey);
    state = localeFromPref(raw);
  }

  Future<void> setOverride(Locale? locale) async {
    state = locale;
    final db = accountHub.primaryDbOrNull;
    if (db == null) return;
    final value = prefFromLocale(locale);
    if (value.isEmpty) {
      await db.deleteMetaValue(prefLocaleKey);
    } else {
      await db.setMetaValue(prefLocaleKey, value);
    }
  }
}
