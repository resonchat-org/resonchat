// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Local persistence (M1: plain SQLite; M5 migrates to SQLCipher +
// Keystore without changing these table shapes).

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:sqlite3/sqlite3.dart' show Database;
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:moxxmpp/moxxmpp.dart' show XmppRosterItem;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

part 'database.g.dart';

/// One conversation (1:1 JID for M1; MUC rooms join at M4/M5).
class Chats extends Table {
  TextColumn get jid => text()();
  TextColumn get title => text().withDefault(const Constant(''))();
  DateTimeColumn get lastActivity =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {jid};
}

/// One stored message. Both the ciphertext context (`encMode`) and —
/// unless the user opts out (Q5) — the plaintext are kept so history
/// survives restarts (M1 acceptance).
class Messages extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get chatJid => text().references(Chats, #jid)();
  TextColumn get sender => text()();

  /// Stanza id, used to match XEP-0184 delivery receipts.
  TextColumn get stanzaId => text().withDefault(const Constant(''))();
  TextColumn get body => text()();
  DateTimeColumn get timestamp =>
      dateTime().withDefault(currentDateAndTime)();
  TextColumn get encMode => text().withDefault(const Constant('none'))();
  BoolColumn get incoming => boolean()();

  /// False until a delivery receipt arrives (XEP-0184).
  BoolColumn get delivered => boolean().withDefault(const Constant(false))();

  /// Set when this message came from another of our own devices
  /// (XEP-0280 carbon), so the UI can avoid a duplicate bubble.
  BoolColumn get isCarbon => boolean().withDefault(const Constant(false))();
}

/// Roster cache + RFC 6121 version, persisted for roster versioning.
class RosterEntries extends Table {
  TextColumn get jid => text()();
  TextColumn get name => text().withDefault(const Constant(''))();
  TextColumn get subscription => text().withDefault(const Constant('none'))();
  TextColumn get ask => text().withDefault(const Constant(''))();
  TextColumn get groups => text().withDefault(const Constant(''))();

  @override
  Set<Column> get primaryKey => {jid};
}

/// Single-row table holding the last roster version we saw.
class Meta extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

@DriftDatabase(tables: [Chats, Messages, RosterEntries, Meta])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  @override
  int get schemaVersion => 1;

  Future<List<RosterEntry>> allRosterEntries() =>
      (select(rosterEntries)).get();

  Future<String?> metaValue(String key) async {
    final row = await (select(meta)..where((m) => m.key.equals(key)))
        .getSingleOrNull();
    return row?.value;
  }

  Future<void> setMetaValue(String key, String value) async {
    await into(meta).insertOnConflictUpdate(
      MetaCompanion(key: Value(key), value: Value(value)),
    );
  }

  Future<void> deleteMetaValue(String key) async {
    await (delete(meta)..where((m) => m.key.equals(key))).go();
  }

  Future<String?> rosterVersion() async {
    final row = await (select(meta)
          ..where((m) => m.key.equals('roster_version')))
        .getSingleOrNull();
    return row?.value;
  }

  /// Applies one roster commit (fetch result or push) atomically.
  Future<void> commitRoster({
    required String? version,
    required List<String> removed,
    required List<XmppRosterItem> modified,
    required List<XmppRosterItem> added,
  }) async {
    await transaction(() async {
      if (removed.isNotEmpty) {
        await (delete(rosterEntries)
              ..where((r) => r.jid.isIn(removed)))
            .go();
      }
      for (final item in [...modified, ...added]) {
        await into(rosterEntries).insertOnConflictUpdate(
          RosterEntriesCompanion(
            jid: Value(item.jid),
            name: Value(item.name ?? ''),
            subscription: Value(item.subscription),
            ask: Value(item.ask ?? ''),
            groups: Value(item.groups.join(',')),
          ),
        );
      }
      if (version != null) {
        await into(meta).insertOnConflictUpdate(
          MetaCompanion(
            key: const Value('roster_version'),
            value: Value(version),
          ),
        );
      }
    });
  }

  /// Chat list, newest activity first. `jid` breaks ties because drift
  /// stores DateTime at second precision.
  Stream<List<Chat>> watchChats() => (select(chats)
        ..orderBy([
          (c) => OrderingTerm.desc(c.lastActivity),
          (c) => OrderingTerm.asc(c.jid),
        ]))
      .watch();

  /// Messages in conversation order. `timestamp` first (so imported
  /// history sorts correctly), then `id` as the insertion-order
  /// tiebreaker for same-second messages.
  Stream<List<Message>> watchMessages(String chatJid) =>
      (select(messages)
            ..where((m) => m.chatJid.equals(chatJid))
            ..orderBy([
              (m) => OrderingTerm.asc(m.timestamp),
              (m) => OrderingTerm.asc(m.id),
            ]))
          .watch();

  /// Creates or updates a chat row. [at] overrides the activity timestamp
  /// (tests and MAM imports need deterministic ordering).
  Future<void> upsertChat(
    String jid, {
    String? title,
    DateTime? at,
  }) async {
    await into(chats).insertOnConflictUpdate(
      ChatsCompanion(
        jid: Value(jid),
        title: Value(title ?? jid),
        lastActivity: Value(at ?? DateTime.now()),
      ),
    );
  }

  Future<void> insertMessage(MessagesCompanion message) async {
    await transaction(() async {
      await into(messages).insert(message);
      // Bump the chat's activity only when the message is newer than what
      // we already recorded (importing old history must not regress it).
      final ts = message.timestamp.present
          ? message.timestamp.value
          : DateTime.now();
      await (update(chats)
            ..where((c) =>
                c.jid.equals(message.chatJid.value) &
                c.lastActivity.isSmallerThanValue(ts)))
          .write(ChatsCompanion(lastActivity: Value(ts)));
    });
  }

  /// Marks one of our outgoing messages as delivered (XEP-0184).
  /// Returns the number of rows updated (0 when the id is unknown).
  Future<int> markDelivered(String chatJid, String stanzaId) {
    return (update(messages)
          ..where((m) =>
              m.chatJid.equals(chatJid) &
              m.stanzaId.equals(stanzaId) &
              m.incoming.equals(false)))
        .write(const MessagesCompanion(delivered: Value(true)));
  }

  /// Preview line for the chat list: the newest message body, prefixed
  /// with the sender when it did not come from us.
  Stream<String?> watchLastMessage(String chatJid) {
    final query = select(messages)
      ..where((m) => m.chatJid.equals(chatJid))
      ..orderBy([
        (m) => OrderingTerm.desc(m.timestamp),
        (m) => OrderingTerm.desc(m.id),
      ])
      ..limit(1);
    return query.watchSingleOrNull().map((row) {
      if (row == null) return null;
      if (row.encMode == 'error') return 'Unable to decrypt';
      final prefix = row.incoming ? '' : 'You: ';
      return '$prefix${row.body}';
    });
  }

  /// Finds an already-stored inbound message by its stanza id, so that a
  /// second copy (e.g. carbon + direct delivery) is not duplicated.
  Future<int?> findByStanzaId(String chatJid, String stanzaId) async {
    if (stanzaId.isEmpty) return null;
    final row = await (select(messages)
          ..where((m) =>
              m.chatJid.equals(chatJid) & m.stanzaId.equals(stanzaId))
          ..limit(1))
        .getSingleOrNull();
    return row?.id;
  }
}

/// Opens the database, encrypted with SQLCipher when the native library is
/// available.
///
/// The passphrase lives in the platform keystore and is generated on first
/// run. Losing it makes the file unreadable, which is the intended
/// behaviour: a rooted device must not be able to read messages.
///
/// Falls back to plain SQLite (with a warning) when SQLCipher is missing,
/// so development on desktop keeps working.
Future<AppDatabase> openAppDatabase() async {
  final dir = await getApplicationDocumentsDirectory();
  final file = File(p.join(dir.path, 'resonchat.sqlite3'));

  final passphrase = await _databasePassphrase();
  if (passphrase != null) {
    try {
      // `package:sqlite3` ships a SQLCipher build selected via the
      // `hooks.user_defines` entry in pubspec.yaml. Applying the key
      // pragma is all that is needed; reading with the wrong key fails,
      // which the probe below turns into a clean fallback.
      void applyKey(Database db) {
        db.execute("PRAGMA key = \"x'${_hex(passphrase)}'\";");
        db.select('SELECT count(*) FROM sqlite_master;');
      }

      final native = NativeDatabase.createInBackground(
        file,
        setup: applyKey,
      );
      final probe = AppDatabase(native);
      await probe.customSelect('SELECT count(*) FROM sqlite_master').get();
      await probe.close();
      return AppDatabase(
        NativeDatabase.createInBackground(file, setup: applyKey),
      );
    } catch (e) {
      debugPrint('SQLCipher unavailable, falling back to plain SQLite: $e');
    }
  }

  return AppDatabase(NativeDatabase.createInBackground(file));
}

/// Lowercase hex of [bytes], for the `PRAGMA key` literal syntax.
String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Reads (or creates) the database passphrase from the platform keystore.
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
