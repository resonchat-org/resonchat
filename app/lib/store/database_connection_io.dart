// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart' show Database, sqlite3;

/// Shared preferences DB (`resonchat.sqlite3`). Not an account store.
Future<QueryExecutor> openPrefsDatabaseConnection() =>
    _openFile('resonchat.sqlite3', expectedUserVersion: 1);

/// Per-account DB (`resonchat_<accountId>.sqlite3`). [accountId] is required.
Future<QueryExecutor> openAccountDatabaseConnection(String accountId) {
  final id = accountId.trim();
  if (id.isEmpty) {
    throw ArgumentError.value(accountId, 'accountId', 'must be non-empty');
  }
  return _openFile('resonchat_$id.sqlite3', expectedUserVersion: 1);
}

/// Opens a Drift [QueryExecutor] for one SQLite file on IO platforms.
Future<QueryExecutor> _openFile(
  String name, {
  required int expectedUserVersion,
}) async {
  final dir = await getApplicationDocumentsDirectory();
  final file = File(p.join(dir.path, name));
  await _deleteIncompatible(file, expectedUserVersion: expectedUserVersion);

  final passphrase = await _databasePassphrase();
  if (passphrase != null) {
    try {
      void applyKey(Database db) {
        db.execute("PRAGMA key = \"x'${_hex(passphrase)}'\";");
        db.select('SELECT count(*) FROM sqlite_master;');
      }

      // Probe SQLCipher before handing the file to Drift.
      final probe = sqlite3.open(file.path);
      try {
        applyKey(probe);
      } finally {
        probe.close();
      }

      return NativeDatabase.createInBackground(file, setup: applyKey);
    } catch (e) {
      debugPrint('SQLCipher unavailable, falling back to plain SQLite: $e');
    }
  }

  return NativeDatabase.createInBackground(file);
}

/// No forward compatibility: wipe files that are not at [expectedUserVersion].
///
/// Probe failures (SQLCipher vs plain, etc.) are left for the open path to
/// handle — only a readable, wrong [user_version] triggers delete.
Future<void> _deleteIncompatible(
  File file, {
  required int expectedUserVersion,
}) async {
  if (!await file.exists()) return;
  try {
    final passphrase = await _databasePassphrase();
    final probe = sqlite3.open(file.path);
    var version = 0;
    try {
      if (passphrase != null) {
        probe.execute("PRAGMA key = \"x'${_hex(passphrase)}'\";");
        probe.select('SELECT count(*) FROM sqlite_master;');
      }
      final row = probe.select('PRAGMA user_version;');
      version = row.isEmpty ? 0 : (row.first.values.first as int?) ?? 0;
    } finally {
      probe.close();
    }
    // Fresh empty files are user_version 0 before Drift migrates — leave them.
    if (version == 0 || version == expectedUserVersion) return;
    await file.delete();
    debugPrint(
      'Deleted incompatible DB ${file.path} (user_version=$version, '
      'expected=$expectedUserVersion)',
    );
  } catch (e) {
    debugPrint('DB probe skipped for ${file.path}: $e');
  }
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Future<List<int>?> _databasePassphrase() async {
  const key = 'resonchat.database.passphrase';
  try {
    const storage = FlutterSecureStorage();
    final existing = await storage.read(key: key);
    if (existing != null) return base64Decode(existing);
    final fresh = <int>[for (var i = 0; i < 32; i++) _rng.nextInt(256)];
    await storage.write(key: key, value: base64Encode(fresh));
    return fresh;
  } catch (e) {
    debugPrint('keystore unavailable for the database key: $e');
    return null;
  }
}

final Random _rng = Random.secure();
