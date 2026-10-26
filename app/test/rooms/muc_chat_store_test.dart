// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Rooms must stay MODE_MULTI across ordinary chat upserts (roster sync,
// inbound activity bumps) — that is what stops a MUC being treated as a
// contact.

import 'package:drift/native.dart';
import 'package:test/test.dart';

import 'package:resonchat/persistence/database.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  test('join persists isGroup and mucNick', () async {
    await db.upsertChat(
      'room@conference.example.org',
      isGroup: true,
      mucNick: 'alice',
      title: 'room@conference.example.org',
    );
    final row = await db.getChat('room@conference.example.org');
    expect(row?.isGroup, isTrue);
    expect(row?.mucNick, 'alice');
  });

  test('a later 1:1-style upsert does not wipe room flags', () async {
    await db.upsertChat(
      'room@conference.example.org',
      isGroup: true,
      mucNick: 'alice',
    );
    // Inbound / roster-style bump — no isGroup / mucNick arguments.
    await db.upsertChat('room@conference.example.org');
    final row = await db.getChat('room@conference.example.org');
    expect(row?.isGroup, isTrue);
    expect(row?.mucNick, 'alice');
  });

  test('groupChatsForJoin only returns rooms with a nick', () async {
    await db.upsertChat('a@conf.example', isGroup: true, mucNick: 'me');
    await db.upsertChat('b@conf.example', isGroup: true, mucNick: '');
    await db.upsertChat('peer@example.org');
    final rooms = await db.groupChatsForJoin();
    expect(rooms.map((c) => c.jid), ['a@conf.example']);
  });

  test('mucPrivateNonAnonymous survives ordinary upserts', () async {
    await db.upsertChat(
      'room@conference.example.org',
      isGroup: true,
      mucNick: 'alice',
      mucPrivateNonAnonymous: true,
    );
    await db.upsertChat('room@conference.example.org');
    final row = await db.getChat('room@conference.example.org');
    expect(row?.mucPrivateNonAnonymous, isTrue);
  });
}
