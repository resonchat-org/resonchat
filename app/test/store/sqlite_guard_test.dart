// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The `execmem` guard around Drift's database opening. See
// `lib/store/sqlite_guard.dart` and flutter/flutter#191385.
//
// These tests cannot reproduce the Android SELinux denial itself (CI allows
// executable memory), so they pin the *behaviour* the guard exists for: Drift's
// built-in Dart SQL functions must not reach sqlite3 on our connection path,
// while everything else keeps working.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:resonchat/store/database.dart';
import 'package:resonchat/store/sqlite_guard.dart';

void main() {
  group('guardedSqlite3 (unit)', () {
    late Sqlite3 sqlite;
    late Database db;

    setUp(() {
      sqlite = guardedSqlite3();
      db = sqlite.openInMemory();
    });
    tearDown(() => db.close());

    test('drops the functions Drift insists on registering', () {
      // Exactly what `useNativeFunctions` does on every Drift open.
      for (final name in ['power', 'current_time_millis', 'moor_contains']) {
        expect(kDriftBuiltinFunctions, contains(name));
        db.createFunction(
          functionName: name,
          function: (args) => null,
          argumentCount: const AllowedArgumentCount.any(),
        );
      }

      // Names that only Drift provides: SQLCipher already ships native math
      // functions, so `power`/`sqrt` cannot tell the guard apart.
      expect(
        () => db.select('SELECT current_time_millis()'),
        throwsA(isA<SqliteException>()),
      );
      expect(
        () => db.select("SELECT moor_contains('abc', 'b')"),
        throwsA(isA<SqliteException>()),
      );
    });

    test('forwards functions that are not Drift built-ins', () {
      db.createFunction(
        functionName: 'resonchat_test',
        function: (args) => 42,
        argumentCount: const AllowedArgumentCount.any(),
      );

      expect(db.select('SELECT resonchat_test()').first.values.first, 42);
    });

    test('delegates ordinary statements and pragmas', () {
      db.execute('CREATE TABLE t (a INTEGER, b TEXT)');
      db.execute('INSERT INTO t (a, b) VALUES (?, ?)', [1, 'one']);

      expect(db.select('SELECT b FROM t').first.values.first, 'one');

      db.userVersion = 7;
      expect(db.userVersion, 7);

      final stmt = db.prepare('SELECT a FROM t');
      stmt.execute();
      expect(stmt.select().first.values.first, 1);
      stmt.close();
    });
  });

  group('Drift opening', () {
    test('stock Drift installs its Dart SQL functions', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);

      // The baseline the guard removes: this is what triggers the trampoline.
      // `current_time_millis` is Drift's own; SQLCipher does not have it.
      final row = await db
          .customSelect('SELECT current_time_millis() AS v')
          .getSingle();
      expect(row.read<int>('v'), greaterThan(0));
    });

    test('guarded opening skips them but keeps the database usable', () async {
      final db = AppDatabase(NativeDatabase.memory(sqlite3: guardedSqlite3));
      addTearDown(db.close);

      expect(await db.customSelect('SELECT 1').get(), isNotEmpty);
      expect(
        () => db.customSelect('SELECT current_time_millis()').get(),
        throwsA(isA<Exception>()),
      );
    });

    test('works through the production background-isolate path', () async {
      // Also proves the resolver survives `Isolate.spawn`: a non-sendable
      // resolver would fail here rather than on a device.
      final dir = Directory.systemTemp.createTempSync('resonchat_guard');
      addTearDown(() => dir.deleteSync(recursive: true));

      final db = AppDatabase(
        NativeDatabase.createInBackground(
          File('${dir.path}/guarded.sqlite3'),
          sqlite3: guardedSqlite3,
        ),
      );
      addTearDown(db.close);

      await db.upsertChat('bob@example.org', title: 'Bob');
      expect(await db.customSelect('SELECT 1').get(), isNotEmpty);
      expect(
        () => db.customSelect('SELECT current_time_millis()').get(),
        throwsA(isA<Exception>()),
      );
    });
  });
}
