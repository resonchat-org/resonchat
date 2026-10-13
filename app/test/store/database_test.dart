// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Storage behaviour that the chat UI depends on: stanza-id dedup
// (carbons must not double-insert) and XEP-0184 delivery receipts.

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:moxxmpp/moxxmpp.dart' show XmppRosterItem;
import 'package:test/test.dart';
import 'package:resonchat/store/database.dart';

void main() {
  late AppDatabase db;

  /// Fixed clock: drift stores DateTime at second precision and returns
  /// local-time values, so tests must not rely on sub-second ordering
  /// or a UTC/local distinction.
  DateTime clock(int offsetSeconds) =>
      DateTime(2026).add(Duration(seconds: offsetSeconds));

  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<void> seedOutgoing(String stanzaId) async {
    await db.upsertChat('bob@example.org');
    await db.insertMessage(
      MessagesCompanion(
        chatJid: const Value('bob@example.org'),
        sender: const Value('me'),
        stanzaId: Value(stanzaId),
        body: const Value('hi'),
        incoming: const Value(false),
      ),
    );
  }

  test('insertMessage bumps the chat activity timestamp', () async {
    await db.upsertChat('bob@example.org', at: clock(0));
    await db.insertMessage(
      MessagesCompanion(
        chatJid: const Value('bob@example.org'),
        sender: const Value('me'),
        body: const Value('hello'),
        timestamp: Value(clock(60)),
        incoming: const Value(false),
      ),
    );
    final after = (await db.watchChats().first).single.lastActivity;
    expect(after, clock(60));
  });

  test('importing older history does not regress the chat activity', () async {
    await db.upsertChat('bob@example.org', at: clock(100));
    await db.insertMessage(
      MessagesCompanion(
        chatJid: const Value('bob@example.org'),
        sender: const Value('me'),
        body: const Value('newer'),
        timestamp: Value(clock(200)),
        incoming: const Value(false),
      ),
    );
    await db.insertMessage(
      MessagesCompanion(
        chatJid: const Value('bob@example.org'),
        sender: const Value('bob@example.org'),
        body: const Value('old history'),
        timestamp: Value(clock(50)),
        incoming: const Value(true),
      ),
    );
    final after = (await db.watchChats().first).single.lastActivity;
    expect(after, clock(200));
  });

  test('findByStanzaId detects an already-stored message', () async {
    await seedOutgoing('stanza-1');
    expect(await db.findByStanzaId('bob@example.org', 'stanza-1'), isNotNull);
    expect(await db.findByStanzaId('bob@example.org', 'stanza-2'), isNull);
  });

  test('findByStanzaId ignores empty ids', () async {
    await seedOutgoing('');
    expect(await db.findByStanzaId('bob@example.org', ''), isNull);
  });

  test('markDelivered only touches our own outgoing messages', () async {
    await db.upsertChat('bob@example.org');
    await db.insertMessage(
      MessagesCompanion(
        chatJid: const Value('bob@example.org'),
        sender: const Value('me'),
        stanzaId: const Value('out-1'),
        body: const Value('sent'),
        incoming: const Value(false),
        // On the wire (after socket write); default 0 is STATUS_RECEIVED.
        sendStatus: const Value(MessageSendStatus.send),
      ),
    );
    await db.insertMessage(
      MessagesCompanion(
        chatJid: const Value('bob@example.org'),
        sender: const Value('bob@example.org/laptop'),
        stanzaId: const Value('in-1'),
        body: const Value('received'),
        incoming: const Value(true),
      ),
    );

    expect(await db.markDelivered('bob@example.org', 'out-1'), 1);
    expect(await db.markDelivered('bob@example.org', 'in-1'), 0);
    expect(await db.markDelivered('bob@example.org', 'missing'), 0);

    final rows = await db.watchMessages('bob@example.org').first;
    final byBody = {for (final r in rows) r.body: r};
    expect(byBody['sent']!.delivered, isTrue);
    expect(byBody['sent']!.sendStatus, MessageSendStatus.sendReceived);
    expect(byBody['received']!.delivered, isFalse);
  });

  test('messages stream is ordered oldest first', () async {
    await db.upsertChat('bob@example.org', at: clock(0));
    for (final (i, body) in ['a', 'b', 'c'].indexed) {
      await db.insertMessage(
        MessagesCompanion(
          chatJid: const Value('bob@example.org'),
          sender: const Value('me'),
          body: Value(body),
          timestamp: Value(clock(10 + i)),
          incoming: const Value(false),
        ),
      );
    }
    final rows = await db.watchMessages('bob@example.org').first;
    expect(rows.map((r) => r.body), ['a', 'b', 'c']);
  });

  test('same-second messages keep insertion order', () async {
    await db.upsertChat('bob@example.org', at: clock(0));
    for (final body in ['first', 'second', 'third']) {
      await db.insertMessage(
        MessagesCompanion(
          chatJid: const Value('bob@example.org'),
          sender: const Value('me'),
          body: Value(body),
          timestamp: Value(clock(10)),
          incoming: const Value(false),
        ),
      );
    }
    final rows = await db.watchMessages('bob@example.org').first;
    expect(rows.map((r) => r.body), ['first', 'second', 'third']);
  });

  test('chats stream is ordered by most recent activity', () async {
    await db.upsertChat('a@example.org', at: clock(10));
    await db.upsertChat('b@example.org', at: clock(20));
    var rows = await db.watchChats().first;
    expect(rows.first.jid, 'b@example.org');

    // Activity in the older chat moves it to the top.
    await db.insertMessage(
      MessagesCompanion(
        chatJid: const Value('a@example.org'),
        sender: const Value('me'),
        body: const Value('x'),
        timestamp: Value(clock(30)),
        incoming: const Value(false),
      ),
    );
    rows = await db.watchChats().first;
    expect(rows.first.jid, 'a@example.org');
  });

  test('upsertChat is idempotent and keeps a single row per JID', () async {
    await db.upsertChat('bob@example.org', title: 'Bob', at: clock(0));
    await db.upsertChat('bob@example.org', title: 'Bob B', at: clock(0));
    final chats = await db.watchChats().first;
    expect(chats.length, 1);
    expect(chats.single.title, 'Bob B');
    expect(await db.allRosterEntries(), isEmpty);
  });

  test('new chats without messages start at the activity epoch', () async {
    await db.upsertChat('bob@example.org', title: 'Bob');
    final chat = (await db.watchChats().first).single;
    expect(chat.lastActivity, chatActivityEpoch);
  });

  test('roster-style upsert does not overwrite lastActivity', () async {
    await db.upsertChat('bob@example.org', at: clock(50));
    await db.upsertChat('bob@example.org', title: 'Bob');
    final chat = (await db.watchChats().first).single;
    expect(chat.title, 'Bob');
    expect(chat.lastActivity, clock(50));
  });

  test('syncChatLastActivity repairs login-stamped rows', () async {
    await db.upsertChat('empty@example.org', at: clock(999));
    await db.upsertChat('busy@example.org', at: clock(999));
    await db.insertMessage(
      MessagesCompanion(
        chatJid: const Value('busy@example.org'),
        sender: const Value('me'),
        body: const Value('hi'),
        timestamp: Value(clock(40)),
        incoming: const Value(false),
      ),
    );
    await db.syncChatLastActivity();
    final byJid = {
      for (final c in await db.watchChats().first) c.jid: c.lastActivity,
    };
    expect(byJid['empty@example.org'], chatActivityEpoch);
    expect(byJid['busy@example.org'], clock(40));
  });

  test('clearChatMessages resets lastActivity to the epoch', () async {
    await db.upsertChat('bob@example.org', at: clock(10));
    await db.insertMessage(
      MessagesCompanion(
        chatJid: const Value('bob@example.org'),
        sender: const Value('me'),
        body: const Value('hi'),
        timestamp: Value(clock(20)),
        incoming: const Value(false),
      ),
    );
    await db.clearChatMessages('bob@example.org');
    expect(
      (await db.watchChats().first).single.lastActivity,
      chatActivityEpoch,
    );
  });

  test('roster commits persist items, version and removals', () async {
    await db.commitRoster(
      version: 'v1',
      removed: const [],
      modified: const [],
      added: const [
        XmppRosterItem(
          jid: 'bob@example.org',
          name: 'Bob',
          subscription: 'both',
        ),
      ],
    );
    expect(await db.rosterVersion(), 'v1');
    expect(await db.allRosterEntries(), hasLength(1));

    // Re-publish without the JID: it must be dropped from the cache.
    await db.commitRoster(
      version: 'v2',
      removed: const ['bob@example.org'],
      modified: const [],
      added: const [],
    );
    expect(await db.allRosterEntries(), isEmpty);
    expect(await db.rosterVersion(), 'v2');
  });
}
