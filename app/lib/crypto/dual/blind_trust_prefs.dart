// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Gajim `omemo_blind_trust`: when on, new devices default to Blind Trust;
// when off, they default to Undecided (not encrypted to until the user picks).

import 'package:resonchat/persistence/prefs_database.dart';

const prefOmemoBlindTrustKey = 'pref_omemo_blind_trust';

/// Default **on**, matching Gajim's account setting default.
Future<bool> loadOmemoBlindTrust([PrefsDatabase? prefs]) async {
  final db = prefs ?? appPrefs;
  final raw = await db.getString(prefOmemoBlindTrustKey);
  if (raw == null) return true;
  return raw == '1';
}

Future<void> saveOmemoBlindTrust(bool enabled, [PrefsDatabase? prefs]) async {
  final db = prefs ?? appPrefs;
  await db.setString(prefOmemoBlindTrustKey, enabled ? '1' : '0');
}
