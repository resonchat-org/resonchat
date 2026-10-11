// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Database-at-rest protection (docs/04 §4, docs/06 M5).
//
// The acceptance criterion is concrete: a rooted device that copies the
// database file away must not be able to read message bodies with `strings`
// or a hex dump. These tests check exactly that.

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:resonchat/store/database.dart';
import 'package:resonchat/store/database_connection_io.dart';

/// Unlocks the database the way `openAppDatabase` does.
///
/// Delegates to the production probe rather than re-implementing it: that probe
/// is what is under test, and a copy here could drift away from it.
void applyKey(Database db, List<int> passphrase) => applyCipherKey(db, passphrase);

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('resonchat_db'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  bool hasCipher() {
    // SQLCipher exposes its version through cipher_version.
    final probe = sqlite3.openInMemory();
    try {
      final result = probe.select('PRAGMA cipher_version;');
      return result.isNotEmpty && result.first.values.first != null;
    } finally {
      probe.close();
    }
  }

  test('the bundled SQLite is SQLCipher', () {
    expect(
      hasCipher(),
      isTrue,
      reason: 'pubspec.yaml must select the sqlcipher source for sqlite3',
    );
  });

  test('a keyed database hides message bodies in the raw file', () async {
    final file = File('${dir.path}/secret.sqlite3');
    final key = List<int>.generate(32, (i) => i + 1);

    final db = AppDatabase(
      NativeDatabase.createInBackground(
        file,
        setup: (raw) {
          applyKey(raw, key);
        },
      ),
    );
    await db.upsertChat('bob@example.org', title: 'Bob');
    await db.insertMessage(
      MessagesCompanion(
        chatJid: const Value('bob@example.org'),
        sender: const Value('bob@example.org'),
        body: const Value('plaintext-canary-9f3a2b'),
        incoming: const Value(true),
      ),
    );
    await db.close();

    // The acceptance test: the canary must not appear anywhere in the file.
    final bytes = file.readAsBytesSync();
    expect(
      _containsSublist(bytes, utf8.encode('plaintext-canary-9f3a2b')),
      isFalse,
      reason: 'message body found in the database file — it is not encrypted',
    );

    // And the schema name must not leak either.
    expect(_containsSublist(bytes, utf8.encode('messages')), isFalse);

    // Opening without the key must fail rather than silently succeed.
    expect(() {
      final raw = sqlite3.open(file.path);
      try {
        raw.select('SELECT * FROM messages;');
      } finally {
        raw.close();
      }
    }, throwsA(anything));

    // With the key it works.
    final reopened = AppDatabase(
      NativeDatabase.createInBackground(
        file,
        setup: (raw) {
          applyKey(raw, key);
        },
      ),
    );
    final rows = await reopened.watchMessages('bob@example.org').first;
    expect(rows.single.body, 'plaintext-canary-9f3a2b');
    await reopened.close();
  });

  test('a wrong passphrase cannot read the database', () async {
    final file = File('${dir.path}/wrong.sqlite3');
    final key = List<int>.generate(32, (i) => i);

    final db = AppDatabase(
      NativeDatabase.createInBackground(
        file,
        setup: (raw) {
          applyKey(raw, key);
        },
      ),
    );
    await db.upsertChat('carol@example.org');
    await db.close();

    expect(() {
      final raw = sqlite3.open(file.path);
      try {
        final wrong = List<int>.filled(32, 9);
        applyKey(raw, wrong);
      } finally {
        raw.close();
      }
    }, throwsA(anything));
  });

  test('an unkeyed database does leak, proving the test can fail', () async {
    // Guards against a false pass: if the canary check were vacuous, this
    // would still pass and the previous test would prove nothing.
    final file = File('${dir.path}/plain.sqlite3');
    final db = AppDatabase(NativeDatabase.createInBackground(file));
    await db.upsertChat('dave@example.org');
    await db.insertMessage(
      MessagesCompanion(
        chatJid: const Value('dave@example.org'),
        sender: const Value('dave@example.org'),
        body: const Value('plaintext-canary-9f3a2b'),
        incoming: const Value(true),
      ),
    );
    await db.close();

    final bytes = file.readAsBytesSync();
    expect(
      _containsSublist(bytes, utf8.encode('plaintext-canary-9f3a2b')),
      isTrue,
    );
  });

  test('the key probe refuses a file that is not encrypted', () async {
    // The bug this pins down: the open path used to catch *any* probe failure
    // and fall back to opening the file unkeyed. A file that is not encrypted
    // would then keep working, silently, while the app went on telling the user
    // (docs/04 §4, docs/08 Q5) that message history is encrypted at rest.
    // Refusing is the only honest outcome — the alternative is a database that
    // quietly is not the one we claim.
    final file = File('${dir.path}/downgrade.sqlite3');
    final plain = AppDatabase(NativeDatabase.createInBackground(file));
    await plain.upsertChat('erin@example.org');
    await plain.close();

    final raw = sqlite3.open(file.path);
    try {
      expect(
        () => applyKey(raw, List<int>.filled(32, 3)),
        throwsA(anything),
        reason: 'a plaintext file must not open as if it were keyed',
      );
    } finally {
      raw.close();
    }
  });
}

bool _containsSublist(List<int> haystack, List<int> needle) {
  if (needle.isEmpty || needle.length > haystack.length) return false;
  outer:
  for (var i = 0; i <= haystack.length - needle.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}
