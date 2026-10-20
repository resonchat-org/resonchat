// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Pre-send tracking check preference (warn before replace; no silent mode).

import 'package:resonchat/persistence/prefs_database.dart';

const prefRemoveTrackingEnabledKey = 'pref_remove_tracking_enabled';

/// Legacy Copinc-style key; migrated on read.
const _legacyModeKey = 'pref_remove_tracking_mode';

Future<bool> loadRemoveTrackingEnabled([PrefsDatabase? prefs]) async {
  final db = prefs ?? appPrefs;
  final raw = await db.getString(prefRemoveTrackingEnabledKey);
  if (raw != null) return raw == '1';

  // Migrate legacy mode: anything other than disabled → on.
  final legacy = await db.getString(_legacyModeKey);
  if (legacy == null) return false; // default off
  final enabled = legacy != 'disabled';
  await db.setString(prefRemoveTrackingEnabledKey, enabled ? '1' : '0');
  return enabled;
}

Future<void> saveRemoveTrackingEnabled(
  bool enabled, [
  PrefsDatabase? prefs,
]) async {
  final db = prefs ?? appPrefs;
  await db.setString(prefRemoveTrackingEnabledKey, enabled ? '1' : '0');
}
