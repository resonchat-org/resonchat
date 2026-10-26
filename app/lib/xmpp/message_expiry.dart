// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Automatic message deletion (Conversations `automatic_message_deletion`).
//
// App-wide retention: messages older than `now − duration` are removed from
// this device only. Attachment files under the private media store are deleted
// with their rows (Copinc-style). Nothing is retracted on the wire.

import 'dart:async';

import 'package:logging/logging.dart';

import 'package:resonchat/account/account_hub.dart';
import 'package:resonchat/persistence/media_store.dart';
import 'package:resonchat/persistence/prefs_database.dart';

final _log = Logger('MessageExpiry');

/// Prefs key — same name as Conversations `AppSettings.AUTOMATIC_MESSAGE_DELETION`.
const kAutomaticMessageDeletionPref = 'automatic_message_deletion';

/// How often to sweep while the app is running (Conversations: 30 minutes).
const kMessageExpiryInterval = Duration(minutes: 30);

/// Retention choices, Gajim `chat_history_max_age` (seconds).
///
/// Declaration order is the slider order: shortest window on the left,
/// [never] (`-1`) on the right. [untilClosed] is `0` — Gajim
/// "Until Gajim is Closed". That value is applied only when the process
/// is going away (`cleanup_chat_history` in `_shutdown_core`), never while
/// a chat is on screen.
enum AutomaticMessageDeletion {
  untilClosed(0),
  oneDay(86400),
  oneWeek(604800),
  oneMonth(2629743),
  threeMonths(7889229),
  sixMonths(15778458),
  oneYear(31556926),
  never(-1);

  const AutomaticMessageDeletion(this.seconds);

  /// Gajim stores never-delete as `-1` and "until closed" as `0`.
  final int seconds;

  /// True for a finite age that may be swept while the app is running.
  ///
  /// [untilClosed] is excluded: a cutoff of "now" would erase the open
  /// transcript. [never] keeps everything.
  bool get deletesWhileRunning => seconds > 0;

  /// Cutoff for the periodic sweep and for dropping archived inbound.
  ///
  /// Null for [never] and [untilClosed].
  DateTime? cutoffAt([DateTime? now]) {
    if (!deletesWhileRunning) return null;
    return (now ?? DateTime.now()).subtract(Duration(seconds: seconds));
  }

  /// Cutoff for Gajim's shutdown sweep.
  ///
  /// [never] skips the sweep. [untilClosed] deletes every row already
  /// stored (`timestamp < now`). A positive age deletes rows older than
  /// that window.
  DateTime? shutdownCutoff([DateTime? now]) {
    if (this == never) return null;
    final clock = now ?? DateTime.now();
    if (seconds <= 0) return clock;
    return clock.subtract(Duration(seconds: seconds));
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
  bool atShutdown = false,
}) async {
  final deletion = setting ?? await loadAutomaticMessageDeletion();
  final cutoff = atShutdown
      ? deletion.shutdownCutoff(now)
      : deletion.cutoffAt(now);
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
