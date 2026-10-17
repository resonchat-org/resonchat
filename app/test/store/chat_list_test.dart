// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Chat-list bookkeeping: pinned order, mute, archive, unread counts.
//
// The unread count is the part worth being careful about. It is the one number
// the user checks against reality — "the badge said 3 and there were 2" — so
// every test here is about it not drifting.

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:test/test.dart';
import 'package:resonchat/store/database.dart';

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  DateTime clock(int seconds) => DateTime(2026).add(Duration(seconds: seconds));

  Future<void> touch(String jid, int at) => db.upsertChat(jid, at: clock(at));

  group('ordering', () {
    test('pinned conversations come first, then most recent', () async {
      await touch('old@example.org', 10);
      await touch('newest@example.org', 30);
      await touch('pinned@example.org', 20);
      await db.setChatFlag('pinned@example.org', pinned: true);

      final order = (await db.watchChats().first).map((c) => c.jid);
      expect(order, [
        'pinned@example.org',
        'newest@example.org',
        'old@example.org',
      ]);
    });

    test('unpinning puts it back by activity', () async {
      await touch('a@example.org', 10);
      await touch('b@example.org', 20);
      await db.setChatFlag('a@example.org', pinned: true);
      await db.setChatFlag('a@example.org', pinned: false);
      final order = (await db.watchChats().first).map((c) => c.jid);
      expect(order, ['b@example.org', 'a@example.org']);
    });

    test('the order is stable for equal activity', () async {
      // Two conversations with the same last-activity second used to swap
      // places between rebuilds, which reads as the list jittering.
      await touch('z@example.org', 10);
      await touch('a@example.org', 10);
      final first = (await db.watchChats().first).map((c) => c.jid).toList();
      final second = (await db.watchChats().first).map((c) => c.jid).toList();
      expect(first, second);
      expect(first, ['a@example.org', 'z@example.org']);
    });
  });

  group('archive', () {
    test('archived conversations leave the main list', () async {
      await touch('kept@example.org', 10);
      await touch('hidden@example.org', 20);
      await db.setChatFlag('hidden@example.org', archived: true);
      expect((await db.watchChats().first).map((c) => c.jid), [
        'kept@example.org',
      ]);
      // Same order as the main list: the archived one is the more recent.
      expect(
        (await db.watchChats(includeArchived: true).first).map((c) => c.jid),
        ['hidden@example.org', 'kept@example.org'],
      );
    });

    test('the archive shows only archived conversations', () async {
      // Getting this wrong makes "Archived" a second copy of the whole chat
      // list, which is worse than having no archive page: the user cannot tell
      // which list they are looking at.
      await touch('kept@example.org', 10);
      await touch('hidden@example.org', 20);
      await db.setChatFlag('hidden@example.org', archived: true);
      expect((await db.watchArchivedChats().first).map((c) => c.jid), [
        'hidden@example.org',
      ]);
    });

    test(
      'archiving everything leaves an empty archive, not an empty list',
      () async {
        await touch('a@example.org', 10);
        await db.setChatFlag('a@example.org', archived: true);
        expect(await db.watchChats().first, isEmpty);
        expect(await db.watchArchivedChats().first, hasLength(1));
        expect(await db.watchChats(includeArchived: true).first, hasLength(1));
      },
    );

    test('a pinned conversation can also be archived', () async {
      // Pin and archive are independent: a user may want a busy conversation
      // out of the way but still findable at the top of the archive.
      await touch('a@example.org', 10);
      await db.setChatFlag('a@example.org', pinned: true);
      await db.setChatFlag('a@example.org', archived: true);
      expect(await db.watchChats().first, isEmpty);
      expect(await db.watchChats(includeArchived: true).first, hasLength(1));
    });
  });

  group('mute', () {
    test('is stored per conversation', () async {
      await touch('a@example.org', 10);
      await touch('b@example.org', 10);
      await db.setChatFlag('a@example.org', muted: true);
      final rows = {
        for (final c in await db.watchChats().first) c.jid: c.muted,
      };
      expect(rows['a@example.org'], isTrue);
      expect(rows['b@example.org'], isFalse);
    });

    test('setting one flag leaves the others alone', () async {
      // A partial update must not reset the flags it does not mention: pinning a
      // muted conversation silently unmuting it would be a bug the user can
      // only notice by being surprised by a notification.
      await touch('a@example.org', 10);
      await db.setChatFlag('a@example.org', muted: true);
      await db.setChatFlag('a@example.org', pinned: true);
      final row = (await db.watchChats().first).single;
      expect(row.muted, isTrue);
      expect(row.pinned, isTrue);
    });

    test('a flag can be set before the conversation exists', () async {
      await db.setChatFlag('new@example.org', pinned: true);
      final row = (await db.watchChats().first).single;
      expect(row.jid, 'new@example.org');
      expect(row.pinned, isTrue);
    });
  });

  group('unread count', () {
    test('counts every arrival', () async {
      await touch('a@example.org', 10);
      // After the read marker: the row is created with last_read_at = now, and
      // anything older is archive replay, which must not count.
      for (var i = 0; i < 3; i++) {
        await db.markChatUnread(
          'a@example.org',
          arrivedAt: DateTime.now().add(Duration(seconds: i + 1)),
        );
      }
      expect((await db.watchChats().first).single.unreadCount, 3);
    });

    test('mark-read clears it', () async {
      await touch('a@example.org', 10);
      await db.markChatUnread('a@example.org', arrivedAt: clock(1));
      await db.markChatRead('a@example.org', at: clock(2));
      final row = (await db.watchChats().first).single;
      expect(row.unreadCount, 0);
      expect(row.lastReadAt, clock(2));
    });

    test(
      'mark-read keeps messages that arrived after the leave marker',
      () async {
        // dispose → unawaited markRead: a message can land (and bump the
        // counter) before the SQL runs. Forcing unread to 0 would hide it.
        await touch('a@example.org', 10);
        await db.markChatRead('a@example.org', at: clock(1));
        await db.insertMessage(
          MessagesCompanion(
            chatJid: const Value('a@example.org'),
            sender: const Value('room@example.org/bob'),
            body: const Value('hey Alice'),
            incoming: const Value(true),
            timestamp: Value(clock(2)),
            mentionsMe: const Value(true),
          ),
        );
        await db.markChatUnread(
          'a@example.org',
          arrivedAt: clock(2),
          mentionsMe: true,
        );
        // Late mark-read with the *leave* time, not "now".
        await db.markChatRead('a@example.org', at: clock(1));
        final row = (await db.watchChats().first).single;
        expect(row.unreadCount, 1);
        expect(row.unreadMentions, 1);
      },
    );

    test('two arrivals are not collapsed into one', () async {
      // The read-modify-write version of this loses a count: both callers read
      // 0, both write 1, and one message is never counted. The user then finds
      // a message already marked read.
      await touch('a@example.org', 10);
      await db.markChatUnread(
        'a@example.org',
        arrivedAt: DateTime.now().add(const Duration(seconds: 1)),
      );
      await db.markChatUnread(
        'a@example.org',
        arrivedAt: DateTime.now().add(const Duration(seconds: 2)),
      );
      expect((await db.watchChats().first).single.unreadCount, 2);
    });

    test('a message older than the read marker does not count', () async {
      // Archive replay delivers old messages. Counting them would show a badge
      // for a conversation the user has already read.
      await touch('a@example.org', 10);
      await db.markChatRead('a@example.org', at: clock(100));
      await db.markChatUnread('a@example.org', arrivedAt: clock(50));
      expect((await db.watchChats().first).single.unreadCount, 0);
    });

    test('a message newer than the read marker counts', () async {
      await touch('a@example.org', 10);
      await db.markChatRead('a@example.org', at: clock(50));
      await db.markChatUnread('a@example.org', arrivedAt: clock(60));
      expect((await db.watchChats().first).single.unreadCount, 1);
    });

    test('marking an unknown conversation read is harmless', () async {
      await db.markChatRead('never-seen@example.org');
      expect(await db.watchChats().first, isEmpty);
    });
  });
}
