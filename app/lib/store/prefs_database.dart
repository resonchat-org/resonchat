// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Process-wide shared preferences (SOCKS, locale, global track). Opened at
// app start. Account credentials stay in the keystore; chat data lives in
// per-account [AppDatabase] files.

import 'package:drift/drift.dart';

import 'database_connection.dart';

part 'prefs_database.g.dart';

/// Key/value store for app-wide prefs (not account-scoped).
class Prefs extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

@DriftDatabase(tables: [Prefs])
class PrefsDatabase extends _$PrefsDatabase {
  PrefsDatabase(super.e);

  /// Schema reset: no legacy migrations. Drift requires a positive version.
  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration =>
      MigrationStrategy(onCreate: (m) async => m.createAll());

  Future<String?> getString(String key) async {
    final row = await (select(
      prefs,
    )..where((t) => t.key.equals(key))).getSingleOrNull();
    return row?.value;
  }

  Future<void> setString(String key, String value) async {
    await into(prefs).insertOnConflictUpdate(
      PrefsCompanion(key: Value(key), value: Value(value)),
    );
  }

  Future<void> remove(String key) async {
    await (delete(prefs)..where((t) => t.key.equals(key))).go();
  }

  /// SOCKS5 proxy (Conversations Tor / unified socket path).
  Future<bool> socks5ProxyEnabled() async =>
      (await getString('pref_socks5_enabled')) == '1';

  Future<String> socks5ProxyHost() async {
    final raw = (await getString('pref_socks5_host'))?.trim() ?? '';
    return raw.isEmpty ? '127.0.0.1' : raw;
  }

  Future<int> socks5ProxyPort() async {
    final raw = await getString('pref_socks5_port');
    final parsed = int.tryParse(raw ?? '');
    if (parsed == null || parsed < 1 || parsed > 65535) return 7890;
    return parsed;
  }

  Future<void> setSocks5ProxyEnabled(bool enabled) =>
      setString('pref_socks5_enabled', enabled ? '1' : '0');

  Future<void> setSocks5ProxyHost(String host) => setString(
    'pref_socks5_host',
    host.trim().isEmpty ? '127.0.0.1' : host.trim(),
  );

  Future<void> setSocks5ProxyPort(int port) =>
      setString('pref_socks5_port', '$port');
}

PrefsDatabase? _prefsSingleton;

PrefsDatabase get appPrefs {
  final p = _prefsSingleton;
  if (p == null) throw StateError('PrefsDatabase not opened');
  return p;
}

void installAppPrefs(PrefsDatabase db) => _prefsSingleton = db;

/// Opens (and installs) the shared prefs DB. Call once from [main].
Future<PrefsDatabase> openAppPrefs() async {
  final existing = _prefsSingleton;
  if (existing != null) return existing;
  final db = PrefsDatabase(await openPrefsDatabaseConnection());
  installAppPrefs(db);
  return db;
}
