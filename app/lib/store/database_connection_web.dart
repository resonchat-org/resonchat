// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Web persistence: same Drift schema as native, hosted by sqlite3.wasm.
// Storage is OPFS when available, otherwise IndexedDB (Drift's fallbacks).

import 'package:drift/drift.dart';
import 'package:drift/wasm.dart';
import 'package:flutter/foundation.dart';

/// Opens a Drift [QueryExecutor] for one account in the browser.
Future<QueryExecutor> openDatabaseConnection({
  String? accountId,
  bool legacyFile = false,
}) async {
  final name = legacyFile || accountId == null || accountId.isEmpty
      ? 'resonchat'
      : 'resonchat_$accountId';

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
