// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Whether developer log mode is on. Separate from `dev_log_io.dart` because
// the web stub shares it and the settings page reads it on every platform.

import '../store/prefs_database.dart';

const devLogEnabledKey = 'pref_dev_log_enabled';

/// Default off: this writes identifiers and message-flow detail to a file the
/// user can hand to someone else.
Future<bool> loadDevLogEnabled([PrefsDatabase? prefs]) async =>
    (await (prefs ?? appPrefs).getString(devLogEnabledKey)) == '1';

Future<void> saveDevLogEnabled(bool enabled, [PrefsDatabase? prefs]) =>
    (prefs ?? appPrefs).setString(devLogEnabledKey, enabled ? '1' : '0');
