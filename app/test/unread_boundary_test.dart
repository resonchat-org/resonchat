// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Where the unread boundary goes.
//
// The interesting property is not that it lands in the right place — it is that
// it is derived from the read *timestamp* rather than from the unread *count*,
// and that in two different situations the answer is "draw nothing" rather than
// "draw a line at the top". A divider with nothing above it is worse than no
// divider: it says "everything below here is unread" when the conversation is
// in fact entirely read.

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:test/test.dart';
import 'package:resonchat/store/database.dart';
import 'package:resonchat/ui/unread.dart';

void main() {
  group('the boundary is a position in the transcript, not a count', () {
    late AppDatabase db;

    setUp(() => db = AppDatabase(NativeDatabase.memory()));
    tearDown(() => db.close());

    DateTime at(int minute) =>
        DateTime(2026, 1, 1).add(Duration(minutes: minute));

    Future<void> seed(String id, int minute, {bool incoming = true}) async {
      await db.upsertChat('peer@example.org');
      await db.insertMessage(
        MessagesCompanion.insert(
          chatJid: 'peer@example.org',
          sender: incoming ? 'peer@example.org/x' : 'me',
          stanzaId: Value(id),
          body: 'body $id',
          incoming: incoming,
          timestamp: Value(at(minute)),
        ),
      );
    }

    Future<List<Message>> messages() =>
        db.watchMessages('peer@example.org').first;

    test('the first message after the read marker', () async {
      await seed('m1', 1);
      await seed('m2', 2);
      await seed('m3', 3);
      final list = await messages();
      expect(firstUnreadId(list, at(1).add(const Duration(seconds: 30))), 'm2');
    });

    test('the marker exactly on a message leaves that message read', () async {
      // Boundary inclusive: the marker records when reading happened, and a
      // message that arrived at that instant was on screen.
      await seed('m1', 1);
      await seed('m2', 2);
      final list = await messages();
      expect(firstUnreadId(list, at(2)), isNull);
      // One second earlier and m2 is the boundary instead — so the boundary is
      // a real position and not merely "the last message".
      expect(
        firstUnreadId(list, at(2).subtract(const Duration(seconds: 1))),
        'm2',
      );
    });

    test('everything read means no boundary at all', () async {
      await seed('m1', 1);
      await seed('m2', 2);
      final list = await messages();
      expect(firstUnreadId(list, at(10)), isNull);
    });

    test('nothing read yet means no boundary either', () async {
      // A divider under every message is not "everything is unread", it is a
      // line the user cannot act on. The badge in the list carries that.
      await seed('m1', 1);
      final list = await messages();
      expect(firstUnreadId(list, null), isNull);
    });

    test('reading on another device means no boundary', () async {
      // The marker is newer than everything we hold. Drawing here would put a
      // line across the top of a conversation with nothing above it.
      await seed('m1', 1);
      final list = await messages();
      expect(firstUnreadId(list, at(99)), isNull);
    });

    test('an old message imported by MAM cannot move the boundary', () async {
      // Archive replay inserts messages *after* the marker was set. The
      // boundary is recomputed from the marker every time, so an old message
      // arriving does not push the divider up above messages the user really
      // has not read. This is why a count would be wrong: the count would grow
      // while the position stayed put.
      await seed('m1', 5);
      await seed('m2', 6);
      await db.markChatRead('peer@example.org', at: at(4));
      await seed('old', 1);
      final list = await messages();
      expect(list.first.stanzaId, 'old');
      expect(firstUnreadId(list, at(4)), 'm1');
    });

    test('a message we could not decrypt still draws the boundary', () async {
      // It renders as a system row rather than a bubble, so "three rows above
      // the bottom" would not be it. Deriving from the timestamp does not care
      // how a row is drawn.
      await db.upsertChat('peer@example.org');
      await db.insertMessage(
        MessagesCompanion.insert(
          chatJid: 'peer@example.org',
          sender: 'peer@example.org/x',
          body: '',
          incoming: true,
          encMode: Value('error'),
          timestamp: Value(at(6)),
        ),
      );
      final list = await messages();
      // The undecryptable row's id is whatever was stored, so assert on the
      // position rather than a hard-coded id.
      expect(firstUnreadId(list, at(4)), unreadAnchorOf(list.single));
    });

    test('unread count places a boundary when the marker finds none', () async {
      // Same-second race: last_read_at equals the message timestamp so
      // isAfter finds nothing, but the badge still says unread.
      await seed('m1', 1);
      await seed('m2', 2);
      await seed('m3', 3);
      final list = await messages();
      expect(firstUnreadId(list, at(3), unreadCount: 0), isNull);
      expect(firstUnreadId(list, at(3), unreadCount: 2), 'm2');
    });
  });
}
