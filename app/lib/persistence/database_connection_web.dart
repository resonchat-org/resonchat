// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Web persistence: same Drift schema as native, hosted by sqlite3.wasm.
// Storage is OPFS when available, otherwise IndexedDB (Drift's fallbacks).

import 'package:flutter/foundation.dart';

import 'package:drift/drift.dart';
import 'package:drift/wasm.dart';

/// Shared preferences DB. Not an account store.
Future<QueryExecutor> openPrefsDatabaseConnection() => _openWasm('resonchat');

/// Per-account DB. [accountId] is required (hashed id in the name).
Future<QueryExecutor> openAccountDatabaseConnection(String accountId) {
  final id = accountId.trim();
  if (id.isEmpty) {
    throw ArgumentError.value(accountId, 'accountId', 'must be non-empty');
  }
  return _openWasm('resonchat_$id');
}

Future<QueryExecutor> _openWasm(String name) async {
  final result = await WasmDatabase.open(
    databaseName: name,
    sqlite3Uri: Uri.parse('sqlite3.wasm'),
    driftWorkerUri: Uri.parse('drift_worker.js'),
  );

  if (result.missingFeatures.isNotEmpty) {
    debugPrint(
      'Drift web missing features for $name: ${result.missingFeatures}. '
      'Using ${result.chosenImplementation}.',
    );
  } else {
    debugPrint('Drift web opened $name via ${result.chosenImplementation}');
  }

  return result.resolvedExecutor;
}
