// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Persist XEP-0198 Stream Management state in the account Drift meta table.

import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:moxxmpp/moxxmpp.dart';

import 'package:resonchat/persistence/database.dart';

const smStateMetaKey = 'sm_state';

/// [StreamManagementManager] that commits counters / resumption id to [db].
class DriftStreamManagementManager extends StreamManagementManager {
  DriftStreamManagementManager(this._db, {super.ackTimeout});

  final AppDatabase _db;
  final _log = Logger('DriftStreamManagementManager');

  @override
  Future<void> commitState() async {
    final s = state;
    final payload = jsonEncode({
      'c2s': s.c2s,
      's2c': s.s2c,
      'streamResumptionId': s.streamResumptionId,
      'streamResumptionLocation': s.streamResumptionLocation,
    });
    try {
      await _db.setMetaValue(smStateMetaKey, payload);
    } catch (e, st) {
      _log.warning('failed to commit SM state: $e', e, st);
    }
  }

  @override
  Future<void> loadState() async {
    try {
      final raw = await _db.metaValue(smStateMetaKey);
      if (raw == null || raw.isEmpty) return;
      final map = jsonDecode(raw) as Map<String, dynamic>;
      await setState(
        StreamManagementState(
          (map['c2s'] as num?)?.toInt() ?? 0,
          (map['s2c'] as num?)?.toInt() ?? 0,
          streamResumptionId: map['streamResumptionId'] as String?,
          streamResumptionLocation: map['streamResumptionLocation'] as String?,
        ),
      );
    } catch (e, st) {
      _log.warning('failed to load SM state: $e', e, st);
    }
  }

  /// Clears persisted resumption so the next bind starts a fresh SM session.
  Future<void> clearPersisted() async {
    await resetState();
    try {
      await _db.deleteMetaValue(smStateMetaKey);
    } catch (e, st) {
      _log.warning('failed to clear SM state: $e', e, st);
    }
  }
}
