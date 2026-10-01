// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Local persistence (M1: plain SQLite; M5 migrates to SQLCipher +
// Keystore without changing these table shapes).

import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
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
  TextColumn get body => text()();
  DateTimeColumn get timestamp =>
      dateTime().withDefault(currentDateAndTime)();
  TextColumn get encMode => text().withDefault(const Constant('none'))();
  BoolColumn get incoming => boolean()();
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

  Stream<List<Chat>> watchChats() => (select(chats)
        ..orderBy([(c) => OrderingTerm.desc(c.lastActivity)]))
      .watch();

  Stream<List<Message>> watchMessages(String chatJid) =>
      (select(messages)
            ..where((m) => m.chatJid.equals(chatJid))
            ..orderBy([(m) => OrderingTerm.asc(m.timestamp)]))
          .watch();

  Future<void> upsertChat(String jid, {String? title}) async {
    await into(chats).insertOnConflictUpdate(
      ChatsCompanion(
        jid: Value(jid),
        title: Value(title ?? jid),
        lastActivity: Value(DateTime.now()),
      ),
    );
  }

  Future<void> insertMessage(MessagesCompanion message) async {
    await transaction(() async {
      await into(messages).insert(message);
      await (update(chats)
            ..where((c) => c.jid.equals(message.chatJid.value)))
          .write(ChatsCompanion(lastActivity: Value(DateTime.now())));
    });
  }
}

/// Opens `resonchat.sqlite3` in the app documents directory.
Future<AppDatabase> openAppDatabase() async {
  final dir = await getApplicationDocumentsDirectory();
  final file = File(p.join(dir.path, 'resonchat.sqlite3'));
  return AppDatabase(NativeDatabase.createInBackground(file));
}
