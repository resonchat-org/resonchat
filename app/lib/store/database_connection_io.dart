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

/// Opens a Drift [QueryExecutor] for one account on IO platforms.
Future<QueryExecutor> openDatabaseConnection({
  String? accountId,
  bool legacyFile = false,
}) async {
  final dir = await getApplicationDocumentsDirectory();
  final name = legacyFile || accountId == null || accountId.isEmpty
      ? 'resonchat.sqlite3'
      : 'resonchat_$accountId.sqlite3';
  final file = File(p.join(dir.path, name));

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
