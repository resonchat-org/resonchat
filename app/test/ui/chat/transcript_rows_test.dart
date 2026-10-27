// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Transcript row indices must match what [ChatMessageList] builds.

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:test/test.dart';

import 'package:resonchat/persistence/database.dart';
import 'package:resonchat/ui/chat/transcript_rows.dart';
import 'package:resonchat/ui/chats/unread.dart';

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  DateTime at(int minute) =>
      DateTime(2026, 1, 1).add(Duration(minutes: minute));

  Future<void> seed(
    String id,
    int minute, {
    bool incoming = true,
    DateTime? day,
  }) async {
    await db.upsertChat('peer@example.org');
    final ts = day ?? at(minute);
    await db.insertMessageRow(
      MessagesCompanion.insert(
        chatJid: 'peer@example.org',
        sender: incoming ? 'peer@example.org/x' : 'me',
        stanzaId: Value(id),
        body: 'body $id',
        incoming: incoming,
        timestamp: Value(ts),
      ),
    );
  }

  Future<List<Message>> messages() =>
      db.watchMessages('peer@example.org').first;

  test('date then message; focus index is the message row', () async {
    await seed('m1', 1);
    await seed('m2', 2);
    final list = await messages();
    final rows = buildTranscriptRows(list);
    expect(rows.map((r) => r.kind).toList(), [
      TranscriptRowKind.date,
      TranscriptRowKind.message,
      TranscriptRowKind.message,
    ]);
    expect(focusRowIndexIn(rows, 'm1'), 1);
    expect(focusRowIndexIn(rows, 'm2'), 2);
    expect(unreadDividerIndexIn(rows), isNull);
  });

  test('unread divider sits before the first unread message', () async {
    await seed('m1', 1);
    await seed('m2', 2);
    await seed('m3', 3);
    final list = await messages();
    final rows = buildTranscriptRows(
      list,
      readAt: at(1).add(const Duration(seconds: 30)),
    );
    expect(rows.map((r) => r.kind).toList(), [
      TranscriptRowKind.date,
      TranscriptRowKind.message, // m1 read
      TranscriptRowKind.unread,
      TranscriptRowKind.message, // m2
      TranscriptRowKind.message, // m3
    ]);
    expect(unreadDividerIndexIn(rows), 2);
    expect(focusRowIndexIn(rows, 'm2'), 3);
    expect(firstUnreadId(list, at(1).add(const Duration(seconds: 30))), 'm2');
  });

  test('loading spinner is index 0 when present', () async {
    await seed('m1', 1);
    final list = await messages();
    final rows = buildTranscriptRows(list, loadingOlder: true);
    expect(rows.first.kind, TranscriptRowKind.loadingOlder);
    expect(focusRowIndexIn(rows, 'm1'), 2); // spinner, date, message
  });

  test('new calendar day inserts another date row', () async {
    await seed('m1', 1, day: DateTime(2026, 1, 1, 10));
    await seed('m2', 2, day: DateTime(2026, 1, 2, 10));
    final list = await messages();
    final rows = buildTranscriptRows(list);
    expect(rows.map((r) => r.kind).toList(), [
      TranscriptRowKind.date,
      TranscriptRowKind.message,
      TranscriptRowKind.date,
      TranscriptRowKind.message,
    ]);
    expect(focusRowIndexIn(rows, 'm2'), 3);
  });
}
