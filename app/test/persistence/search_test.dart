// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Message search.
//
// The only interesting question here is what a result set must *not* contain.
// Search that shows a message the user cannot see is worse than no search at
// all: it tells them a conversation contains something it does not.

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:test/test.dart';

import 'package:resonchat/domain/messages_service.dart';
import 'package:resonchat/persistence/database.dart';

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  DateTime clock(int seconds) => DateTime(2026).add(Duration(seconds: seconds));

  Future<void> seed(
    String chat,
    String body, {
    int at = 0,
    bool incoming = false,
    String sender = 'me',
    String? stanzaId,
  }) async {
    await db.upsertChat(chat);
    await db.insertMessageRow(
      MessagesCompanion.insert(
        chatJid: chat,
        sender: sender,
        body: body,
        incoming: incoming,
        timestamp: Value(clock(at)),
        stanzaId: Value(stanzaId ?? 'id-$body'),
      ),
    );
  }

  group('matching', () {
    test('finds a substring anywhere in the body', () async {
      await seed('a@example.org', 'the meeting is at noon');
      await seed('a@example.org', 'unrelated');
      final hits = await db.searchMessages('meeting').first;
      expect(hits.map((m) => m.body), ['the meeting is at noon']);
    });

    test(
      'is case-insensitive, because a user typing ok means OK too',
      () async {
        // Making someone reach for a capitals toggle to find their own message
        // is the kind of friction that gets reported as "search is broken".
        await seed('a@example.org', 'OK thanks');
        expect(await db.searchMessages('ok').first, hasLength(1));
        await seed('a@example.org', 'MIXED Case');
        expect(await db.searchMessages('mixed').first, hasLength(1));
      },
    );

    test('an empty needle returns nothing rather than everything', () async {
      // The dangerous failure: an empty query matching all rows turns "I typed
      // nothing" into "here is your entire history".
      await seed('a@example.org', 'anything');
      expect(await db.searchMessages('').first, isEmpty);
      expect(await db.searchMessages('   ').first, isEmpty);
    });

    test(
      'a needle of only wildcards matches nothing rather than everything',
      () async {
        // `LIKE '%%%'` is true of every row. Same failure as above, reached by
        // typing three percent signs.
        await seed('a@example.org', 'anything');
        expect(await db.searchMessages('%%%').first, isEmpty);
      },
    );

    test('results are newest first', () async {
      await seed('a@example.org', 'needle one', at: 10);
      await seed('a@example.org', 'needle two', at: 20);
      await seed('a@example.org', 'needle three', at: 30);
      final hits = await db.searchMessages('needle').first;
      expect(hits.map((m) => m.body), [
        'needle three',
        'needle two',
        'needle one',
      ]);
    });

    test('the result set is capped', () async {
      // A search that returns the whole archive is a search that hangs.
      for (var i = 0; i < 30; i++) {
        await seed('a@example.org', 'hit $i', at: i);
      }
      expect(await db.searchMessages('hit', limit: 10).first, hasLength(10));
    });
  });

  group('what a result must not contain', () {
    test('a message we could not decrypt', () async {
      // Its body is a placeholder, and a placeholder that happens to contain
      // the needle would send the user looking for text that does not exist.
      await db.upsertChat('a@example.org');
      await db.insertMessageRow(
        MessagesCompanion.insert(
          chatJid: 'a@example.org',
          sender: 'a@example.org/x',
          body: '',
          incoming: true,
          encMode: Value('error'),
        ),
      );
      expect(
        await db.searchMessages('this message is encrypted').first,
        isEmpty,
      );
    });

    test('the encrypted placeholder itself', () async {
      // Stored exactly as the app stores an unopenable message: placeholder
      // body, enc_mode = error. A body search that ignores the second half of
      // that pair fills the results with the same sentence, once per message
      // nobody could read.
      await db.upsertChat('a@example.org');
      await db.insertMessageRow(
        MessagesCompanion.insert(
          chatJid: 'a@example.org',
          sender: 'a@example.org/x',
          body: encryptedBodyFallbackText,
          incoming: true,
          encMode: Value('error'),
        ),
      );
      expect(await db.searchMessages('encrypted').first, isEmpty);
      expect(await db.searchMessages('supported client').first, isEmpty);
    });

    test('a retracted message', () async {
      // The body is kept for the sender's own record, so a bare body search
      // would keep surfacing something the user deliberately removed.
      await seed('a@example.org', 'the secret plan');
      await MessagesService(db).markRetracted(
        (await db.watchMessages('a@example.org').first).single.stanzaId,
      );
      expect(await db.searchMessages('secret plan').first, isEmpty);
    });

    test('another conversation, when searching one', () async {
      await seed('a@example.org', 'shared word');
      await seed('b@example.org', 'shared word');
      final hits = await db.searchInChat('a@example.org', 'shared').first;
      expect(hits.map((m) => m.chatJid), ['a@example.org']);
    });
  });

  group('searching one conversation', () {
    test('finds only that conversation', () async {
      await seed('a@example.org', 'needle');
      await seed('b@example.org', 'needle');
      expect(
        await db.searchInChat('b@example.org', 'needle').first,
        hasLength(1),
      );
    });

    test('an empty needle returns nothing', () async {
      await seed('a@example.org', 'needle');
      expect(await db.searchInChat('a@example.org', '').first, isEmpty);
    });
  });
}

/// The body a client stores for a message it could not open.
const encryptedBodyFallbackText =
    'This message is encrypted. Use a supported client to read it.';
