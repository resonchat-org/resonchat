// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// A `waiting` outgoing row only exists between the local insert and the socket
// write. If the process dies in that window, nothing is left to move it on and
// the bubble shows a clock forever. Reconciliation must fail exactly those
// stale rows, and never a send that is still resolving.

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:test/test.dart';

import 'package:resonchat/persistence/database.dart';
import 'package:resonchat/xmpp/message_send_status.dart';

void main() {
  late AppDatabase db;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await db.upsertChat('a@example.org');
  });
  tearDown(() => db.close());

  Future<void> seed(
    String stanzaId, {
    required DateTime at,
    required int status,
  }) => db.insertMessageRow(
    MessagesCompanion.insert(
      chatJid: 'a@example.org',
      sender: 'me',
      stanzaId: Value(stanzaId),
      body: 'body $stanzaId',
      timestamp: Value(at),
      incoming: false,
      sendStatus: Value(status),
    ),
  );

  Future<int> statusOf(String stanzaId) async {
    final row =
        await (db.select(db.messages)..where(
              (m) =>
                  m.chatJid.equals('a@example.org') &
                  m.stanzaId.equals(stanzaId),
            ))
            .getSingle();
    return row.sendStatus;
  }

  test('only an old waiting row is failed', () async {
    final now = DateTime.now();
    await seed(
      'old-waiting',
      at: now.subtract(const Duration(minutes: 5)),
      status: MessageSendStatus.waiting,
    );
    await seed(
      'fresh-waiting',
      at: now.subtract(const Duration(seconds: 10)),
      status: MessageSendStatus.waiting,
    );
    await seed(
      'old-sent',
      at: now.subtract(const Duration(minutes: 5)),
      status: MessageSendStatus.send,
    );

    final changed = await db.failStaleOutgoingWaiting(
      'a@example.org',
      before: now.subtract(const Duration(minutes: 2)),
      reason: 'not connected',
    );

    expect(changed, 1);
    expect(await statusOf('old-waiting'), MessageSendStatus.sendFailed);
    expect(await statusOf('fresh-waiting'), MessageSendStatus.waiting);
    expect(await statusOf('old-sent'), MessageSendStatus.send);
  });
}
