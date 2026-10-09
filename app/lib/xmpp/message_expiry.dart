// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Automatic message deletion (Conversations `automatic_message_deletion`).
//
// App-wide retention: messages older than `now − duration` are removed from
// this device only. Attachment files under the private media store are deleted
// with their rows (Copinc-style). Nothing is retracted on the wire.

import 'dart:async';

import 'package:logging/logging.dart';

import '../account/account_hub.dart';
import '../platform/media_store.dart';
import '../store/prefs_database.dart';

final _log = Logger('MessageExpiry');

/// Prefs key — same name as Conversations `AppSettings.AUTOMATIC_MESSAGE_DELETION`.
const kAutomaticMessageDeletionPref = 'automatic_message_deletion';

/// How often to sweep while the app is running (Conversations: 30 minutes).
const kMessageExpiryInterval = Duration(minutes: 30);

/// Retention choices stored as **seconds** (Conversations arrays.xml).
enum AutomaticMessageDeletion {
  never(0),
  oneDay(86400),
  oneWeek(604800),
  thirtyDays(2592000),
  sixMonths(15811200);

  const AutomaticMessageDeletion(this.seconds);

  final int seconds;

  bool get deletes => seconds > 0;

  /// Cutoff instant: messages with `timestamp < cutoff` expire.
  DateTime? cutoffAt([DateTime? now]) {
    if (!deletes) return null;
    return (now ?? DateTime.now()).subtract(Duration(seconds: seconds));
  }

  static AutomaticMessageDeletion fromStored(String? raw) {
    final n = int.tryParse(raw ?? '');
    if (n == null) return AutomaticMessageDeletion.never;
    for (final v in AutomaticMessageDeletion.values) {
      if (v.seconds == n) return v;
    }
    return AutomaticMessageDeletion.never;
  }
}

Future<AutomaticMessageDeletion> loadAutomaticMessageDeletion([
  PrefsDatabase? prefs,
]) async {
  final db = prefs ?? appPrefs;
  return AutomaticMessageDeletion.fromStored(
    await db.getString(kAutomaticMessageDeletionPref),
  );
}

Future<void> saveAutomaticMessageDeletion(
  AutomaticMessageDeletion value, {
  PrefsDatabase? prefs,
}) async {
  final db = prefs ?? appPrefs;
  await db.setString(kAutomaticMessageDeletionPref, '${value.seconds}');
}

/// Deletes expired message rows (and their cached files) for every open session.
Future<int> expireOldMessagesAcrossAccounts({
  AutomaticMessageDeletion? setting,
  DateTime? now,
}) async {
  final deletion = setting ?? await loadAutomaticMessageDeletion();
  final cutoff = deletion.cutoffAt(now);
  if (cutoff == null) return 0;

  var total = 0;
  for (final session in accountHub.sessions) {
    try {
      final paths = await session.db.localPathsOlderThan(cutoff);
      final n = await session.db.expireMessagesOlderThan(cutoff);
      total += n;
      await mediaStore.deletePaths(paths);
    } catch (e, st) {
      _log.warning('expire for ${session.account.id}: $e\n$st');
    }
  }
  if (total > 0) {
    _log.info('expired $total message(s) older than $cutoff');
  }
  return total;
}

/// Periodic + on-demand expiry tied to [AppWiring] lifetime.
class MessageExpiryRunner {
  MessageExpiryRunner();

  Timer? _timer;
  bool _running = false;

  void start() {
    stop();
    unawaited(runOnce());
    _timer = Timer.periodic(kMessageExpiryInterval, (_) {
      unawaited(runOnce());
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> runOnce() async {
    if (_running) return;
    _running = true;
    try {
      await expireOldMessagesAcrossAccounts();
    } finally {
      _running = false;
    }
  }
}
