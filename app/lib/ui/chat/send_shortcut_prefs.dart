// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Desktop composer send shortcut. Default Ctrl+Enter; optional Enter-to-send.
// Mobile never reads this.

import 'package:flutter/foundation.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:resonchat/persistence/prefs_database.dart';

const prefSendWithEnterKey = 'pref_send_with_enter';

/// Linux / Windows / macOS — not phones, even with a hardware keyboard.
bool get isDesktopSendShortcutHost {
  switch (defaultTargetPlatform) {
    case TargetPlatform.linux:
    case TargetPlatform.windows:
    case TargetPlatform.macOS:
      return true;
    case TargetPlatform.android:
    case TargetPlatform.iOS:
    case TargetPlatform.fuchsia:
      return false;
  }
}

/// `true` = Enter sends; `false` (default) = Ctrl+Enter sends.
Future<bool> loadSendWithEnter([PrefsDatabase? prefs]) async {
  final db = prefs ?? appPrefs;
  final raw = await db.getString(prefSendWithEnterKey);
  return raw == '1';
}

Future<void> saveSendWithEnter(bool enabled, [PrefsDatabase? prefs]) async {
  final db = prefs ?? appPrefs;
  await db.setString(prefSendWithEnterKey, enabled ? '1' : '0');
}

final sendWithEnterProvider =
    StateNotifierProvider<SendWithEnterNotifier, bool>((ref) {
      return SendWithEnterNotifier();
    });

class SendWithEnterNotifier extends StateNotifier<bool> {
  SendWithEnterNotifier() : super(false) {
    _load();
  }

  Future<void> _load() async {
    state = await loadSendWithEnter();
  }

  Future<void> setEnabled(bool enabled) async {
    state = enabled;
    await saveSendWithEnter(enabled);
  }
}
