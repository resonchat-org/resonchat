// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Storage behaviour that the chat UI depends on: stanza-id dedup
// (carbons must not double-insert) and XEP-0184 delivery receipts.

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:moxxmpp/moxxmpp.dart' show XmppRosterItem;
import 'package:test/test.dart';

import 'package:resonchat/persistence/database.dart';
import 'package:resonchat/xmpp/chat_notify_mode.dart';
import 'package:resonchat/xmpp/message_send_status.dart';
import 'package:resonchat/xmpp/sticker_link.dart';

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

  test('updateEncMode rewrites only our own outgoing row', () async {
    await seedOutgoing('out-1');
    await db.insertMessage(
      MessagesCompanion(
        chatJid: const Value('bob@example.org'),
        sender: const Value('bob@example.org'),
        stanzaId: const Value('out-1'),
        body: const Value('theirs'),
        incoming: const Value(true),
      ),
    );

    // The row is queued with the track the composer was set to; the track
    // resolution that follows can substitute a different one.
    expect(await db.updateEncMode('bob@example.org', 'out-1', 'pq'), 1);
    expect(await db.updateEncMode('bob@example.org', 'missing', 'pq'), 0);

    final rows = await db.watchMessages('bob@example.org').first;
    final byBody = {for (final r in rows) r.body: r};
    expect(byBody['hi']!.encMode, 'pq');
    expect(
      byBody['theirs']!.encMode,
      isNot('pq'),
      reason: 'an inbound message must not be rewritten',
    );
  });

  test('deleteOutgoingByStanzaId drops only the placeholder row', () async {
    await seedOutgoing('out-1');
    await db.insertMessage(
      MessagesCompanion(
        chatJid: const Value('bob@example.org'),
        sender: const Value('bob@example.org'),
        stanzaId: const Value('out-1'),
        body: const Value('theirs'),
        incoming: const Value(true),
      ),
    );

    // A send cancelled at a track dialog must leave nothing behind; only the
    // outgoing row with that id is affected.
    expect(await db.deleteOutgoingByStanzaId('bob@example.org', 'out-1'), 1);
    expect(await db.deleteOutgoingByStanzaId('bob@example.org', 'out-1'), 0);

    final rows = await db.watchMessages('bob@example.org').first;
    expect(rows.map((r) => r.body), ['theirs']);
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

  test(
    'a saved sticker starts with empty links and updates one mode',
    () async {
      final image = Uint8List.fromList(const [1, 2, 3, 4]);
      final saved = await db.addSticker(image: image, mime: 'image/png');
      expect(saved.hashMatched, isFalse);
      final id = saved.id;
      final stored = await db.stickerById(id);
      expect(stored, isNotNull);
      expect(stored!.contentHash, await stickerContentHash(image));
      expect(stored.plainUrl, isEmpty);
      expect(stored.omemoUrl, isEmpty);
      expect(stored.pqUrl, isEmpty);
      expect(stored.plainUploadedAt, isNull);
      expect(stored.omemoUploadedAt, isNull);
      expect(stored.pqUploadedAt, isNull);

      final again = await db.addSticker(image: image, mime: 'image/jpeg');
      expect(again.hashMatched, isTrue);
      expect(again.id, id);
      expect((await db.stickerById(id))!.mime, 'image/png');

      final other = await db.addSticker(
        image: Uint8List.fromList(const [9, 9, 9]),
        mime: 'image/png',
      );
      expect(other.hashMatched, isFalse);
      expect(other.id, isNot(id));

      final moved = await db.addSticker(image: image, mime: 'image/png');
      expect(moved.hashMatched, isTrue);
      final order = await db.watchStickers().first;
      expect(order.map((s) => s.id).toList(), [other.id, id]);
      await db.deleteSticker(other.id);

      final at = DateTime(2026, 1, 2, 3, 4, 5);
      await db.rememberStickerLink(
        id: id,
        kind: StickerSendKind.omemo,
        url: 'aesgcm://files.example/a#k',
        uploadedAt: at,
      );
      final after = (await db.stickerById(id))!;
      expect(after.omemoUrl, 'aesgcm://files.example/a#k');
      expect(after.omemoUploadedAt, at);
      expect(after.plainUrl, isEmpty);
      expect(after.pqUrl, isEmpty);
      expect(after.plainUploadedAt, isNull);
      expect(after.pqUploadedAt, isNull);

      await db.deleteSticker(id);
      expect(await db.stickerById(id), isNull);
    },
  );

  test('Still notify list survives a mode change', () async {
    await db.upsertChat('room@conference.example', isGroup: true);
    await db.setChatNotifySettings(
      'room@conference.example',
      mode: ChatNotifyMode.never,
      except: const ['alice@example.org', 'nick:bob'],
    );
    final muted = await db.getChat('room@conference.example');
    expect(muted!.muted, isTrue);
    expect(decodeNotifyExcept(muted.notifyExcept), [
      'alice@example.org',
      'nick:bob',
    ]);

    await db.setChatNotifyMode('room@conference.example', ChatNotifyMode.all);
    final unmuted = await db.getChat('room@conference.example');
    expect(unmuted!.muted, isFalse);
    expect(decodeNotifyExcept(unmuted.notifyExcept), [
      'alice@example.org',
      'nick:bob',
    ]);
  });

  test(
    'a group displayed marker covers that message and earlier ones',
    () async {
      await db.upsertChat('room@conference.example', isGroup: true);
      Future<void> outgoing(String id, int seconds) {
        return db.insertMessage(
          MessagesCompanion(
            chatJid: const Value('room@conference.example'),
            sender: const Value('me'),
            stanzaId: Value(id),
            roomStanzaId: Value('room-$id'),
            body: Value(id),
            timestamp: Value(clock(seconds)),
            incoming: const Value(false),
          ),
        );
      }

      await outgoing('early', 10);
      await outgoing('marked', 20);
      await outgoing('later', 30);
      await db.noteGroupRead(
        chatJid: 'room@conference.example',
        markerId: 'room-marked',
        readerJid: 'Ada@Example.org',
      );
      final rows = await (db.select(
        db.messages,
      )..orderBy([(m) => OrderingTerm.asc(m.timestamp)])).get();
      expect(rows.map((m) => m.readBy).toList(), [
        '["ada@example.org"]',
        '["ada@example.org"]',
        '[]',
      ]);
    },
  );
}
