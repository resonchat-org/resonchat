// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// How much archive to pull when coming online or joining a room.
//
// Count mode follows Conversations' cap (a finite number of messages).
// Days mode follows Gajim: a time window, then page until the archive
// says it is done — Gajim does not stop at a message count, so neither
// do we. There is no "no threshold" choice. Gajim's private-room default
// of unlimited sync is not offered; the longest window is one year.

import 'package:resonchat/persistence/prefs_database.dart';

/// What limits automatic MAM catch-up. [off] fetches nothing on its own.
enum HistorySyncMode { off, count, days }

/// Stored choice for automatic history fetch.
class HistorySyncSetting {
  const HistorySyncSetting({
    required this.mode,
    required this.count,
    required this.days,
  });

  final HistorySyncMode mode;

  /// Used when [mode] is [HistorySyncMode.count]. Always one of [countOptions].
  final int count;

  /// Used when [mode] is [HistorySyncMode.days]. Always one of [dayOptions].
  /// Never zero: a private room must not sync without a time limit.
  final int days;

  /// Round message counts. 500 is the default; 5000 is the largest.
  static const List<int> countOptions = [50, 100, 200, 500, 1000, 2000, 5000];

  /// Gajim's day presets (1, 2, 7, 30), extended with a quarter, half a
  /// year, and a year. 365 is the longest. Zero is not a choice.
  static const List<int> dayOptions = [1, 2, 7, 30, 90, 180, 365];

  static const int defaultCount = 500;
  static const int defaultDays = 7;

  static const HistorySyncSetting fallback = HistorySyncSetting(
    mode: HistorySyncMode.count,
    count: defaultCount,
    days: defaultDays,
  );

  static const String modeKey = 'pref_history_sync_mode';
  static const String countKey = 'pref_history_sync_count';
  static const String daysKey = 'pref_history_sync_days';

  /// Snaps [value] onto [countOptions]. Values outside the list move to the
  /// nearest end, so a stored 0 or a huge number cannot mean "unlimited".
  static int snapCount(int value) => _snap(value, countOptions);

  /// Snaps [value] onto [dayOptions]. 0 (Gajim "no threshold") becomes the
  /// shortest window, not an open-ended sync.
  static int snapDays(int value) => _snap(value, dayOptions);

  static int _snap(int value, List<int> options) {
    if (options.contains(value)) return value;
    if (value <= options.first) return options.first;
    if (value >= options.last) return options.last;
    var best = options.first;
    var bestDistance = (value - best).abs();
    for (final option in options) {
      final distance = (value - option).abs();
      if (distance < bestDistance) {
        best = option;
        bestDistance = distance;
      }
    }
    return best;
  }

  factory HistorySyncSetting.fromStored({
    String? mode,
    String? count,
    String? days,
  }) {
    final parsed = switch (mode) {
      'off' => HistorySyncMode.off,
      'days' => HistorySyncMode.days,
      _ => HistorySyncMode.count,
    };
    return HistorySyncSetting(
      mode: parsed,
      count: snapCount(int.tryParse(count ?? '') ?? defaultCount),
      days: snapDays(int.tryParse(days ?? '') ?? defaultDays),
    );
  }

  HistorySyncSetting copyWith({HistorySyncMode? mode, int? count, int? days}) {
    return HistorySyncSetting(
      mode: mode ?? this.mode,
      count: count ?? this.count,
      days: days ?? this.days,
    );
  }
}

Future<HistorySyncSetting> loadHistorySyncSetting(PrefsDatabase prefs) async {
  return HistorySyncSetting.fromStored(
    mode: await prefs.getString(HistorySyncSetting.modeKey),
    count: await prefs.getString(HistorySyncSetting.countKey),
    days: await prefs.getString(HistorySyncSetting.daysKey),
  );
}

Future<void> saveHistorySyncSetting(
  PrefsDatabase prefs,
  HistorySyncSetting setting,
) async {
  await prefs.setString(HistorySyncSetting.modeKey, setting.mode.name);
  await prefs.setString(HistorySyncSetting.countKey, '${setting.count}');
  await prefs.setString(HistorySyncSetting.daysKey, '${setting.days}');
}

/// Whether another MAM page should be requested.
///
/// Days mode keeps going until the archive reports [complete] or the cursor
/// stops moving. It does not look at [fetched]. Count mode also stops once
/// [fetched] reaches [messageLimit].
bool historySyncShouldContinue({
  required HistorySyncMode mode,
  required bool complete,
  required int fetched,
  required bool cursorAdvanced,
  int? messageLimit,
}) {
  if (mode == HistorySyncMode.off) return false;
  if (complete || !cursorAdvanced) return false;
  if (mode == HistorySyncMode.count) {
    final limit = messageLimit ?? 0;
    if (limit <= 0 || fetched >= limit) return false;
  }
  return true;
}
