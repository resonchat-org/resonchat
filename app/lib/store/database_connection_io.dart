// Copyright (C) 2026 ResonChat contributors.
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

import 'sqlite_guard.dart';

/// Shared preferences DB (`resonchat.sqlite3`). Not an account store.
Future<QueryExecutor> openPrefsDatabaseConnection() =>
    _openFile('resonchat.sqlite3', maxReadableVersion: 1);

/// Must match [AppDatabase.schemaVersion] in `database.dart`.
///
/// Used only to refuse *newer* files we cannot migrate. Older versions are
/// left for Drift [MigrationStrategy.onUpgrade].
const int kAccountSchemaVersion = 4;

/// Per-account DB (`resonchat_<accountId>.sqlite3`). [accountId] is required.
Future<QueryExecutor> openAccountDatabaseConnection(String accountId) {
  final id = accountId.trim();
  if (id.isEmpty) {
    throw ArgumentError.value(accountId, 'accountId', 'must be non-empty');
  }
  return _openFile(
    'resonchat_$id.sqlite3',
    maxReadableVersion: kAccountSchemaVersion,
  );
}

/// Unlocks [db] with [passphrase] and proves that it worked.
///
/// Proving it is the whole point. `PRAGMA key` is silently ignored by a plain
/// SQLite build (unknown pragmas are not errors), and an *incorrect* key is
/// only detected on the first read — so a probe that merely issues the pragma
/// happily reports success on a connection that is not encrypted. Both checks
/// below turn a silent downgrade into a loud failure:
///
///  * `cipher_version` is empty unless SQLCipher is actually linked in;
///  * the `sqlite_master` read forces the key to be used, and throws if the
///    file does not open with it.
///
/// Exposed rather than private so `test/store/` can pin both behaviours.
void applyCipherKey(Database db, List<int> passphrase) {
  db.execute("PRAGMA key = \"x'${_hex(passphrase)}'\";");

  final cipher = db.select('PRAGMA cipher_version;');
  if (cipher.isEmpty || cipher.first.values.first == null) {
    throw StateError(
      'SQLCipher is not available in this build (cipher_version is empty), '
      'so the database cannot be encrypted. Refusing to open it unencrypted.',
    );
  }

  db.select('SELECT count(*) FROM sqlite_master;');
}

/// Opens a Drift [QueryExecutor] for one SQLite file on IO platforms.
Future<QueryExecutor> _openFile(
  String name, {
  required int maxReadableVersion,
}) async {
  final dir = await getApplicationDocumentsDirectory();
  final file = File(p.join(dir.path, name));
  await _deleteIncompatible(file, maxReadableVersion: maxReadableVersion);

  final passphrase = await _databasePassphrase();
  if (passphrase != null) {
    // Probe before handing the file to Drift, so a failure is reported here,
    // with a message about the key, instead of surfacing later as a query error.
    final probe = sqlite3.open(file.path);
    try {
      applyCipherKey(probe, passphrase);
    } finally {
      probe.close();
    }

    // `sqlite3:` goes through `guardedSqlite3` so Drift's unconditional
    // `useNativeFunctions()` is skipped — registering a Dart SQL function needs
    // executable memory, which Android denies to apps (SIGABRT at startup).
    // See `sqlite_guard.dart`.
    return NativeDatabase.createInBackground(
      file,
      sqlite3: guardedSqlite3,
      setup: (db) => applyCipherKey(db, passphrase),
    );
  }

  // No key: the secure store could not be read. Opening the file here would put
  // chat history on disk in the clear and still report success, so an existing
  // file is left alone and a new one is not created.
  if (await file.exists()) {
    throw StateError(
      'The database key is unavailable, so ${file.path} cannot be opened. '
      'Not falling back to an unencrypted database.',
    );
  }
  throw StateError(
    'The database key is unavailable, so ${file.path} cannot be created. '
    'Not creating an unencrypted database.',
  );
}

/// Wipe only databases from a *newer* build than this one can read.
///
/// Older [user_version] values are migrated by Drift. Wiping on any mismatch
/// (the previous behaviour) deleted the account DB whenever
/// [AppDatabase.schemaVersion] moved past the hardcoded probe value — empty
/// chat list on the next cold start.
///
/// Probe failures (SQLCipher vs plain, etc.) are left for the open path.
Future<void> _deleteIncompatible(
  File file, {
  required int maxReadableVersion,
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
    // 0 = fresh file before Drift migrates. version <= max = we can open/migrate.
    if (version == 0 || version <= maxReadableVersion) return;
    await file.delete();
    debugPrint(
      'Deleted forward-incompatible DB ${file.path} (user_version=$version, '
      'maxReadable=$maxReadableVersion)',
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
