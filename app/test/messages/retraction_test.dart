// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Retraction (XEP-0424) and correction (XEP-0308) in the store.
//
// Both are "a later instruction about an earlier message", and both are keyed
// on the origin-id rather than the server's stanza id — the same reason
// reactions are. An instruction that arrives before the message it refers to
// is ordinary, not exceptional, and the result must be the same one row either
// way round.

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:test/test.dart';

import 'package:resonchat/persistence/database.dart';

void main() {
  late AppDatabase db;
  const chat = 'peer@example.org';
  const id = 'origin-id-1';

  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<Message> store({
    required String stanzaId,
    String body = 'the original text',
    bool incoming = false,
  }) async {
    await db.upsertChat(chat);
    await db.insertMessage(
      MessagesCompanion.insert(
        chatJid: chat,
        sender: incoming ? 'peer@example.org/x' : 'me',
        stanzaId: Value(stanzaId),
        body: body,
        incoming: incoming,
      ),
    );
    return (await db.watchMessages(chat).first).firstWhere(
      (m) => m.stanzaId == stanzaId,
    );
  }

  group('retraction', () {
    test('marks the message and keeps the body', () async {
      await store(stanzaId: id);
      expect(await db.markRetracted(id), isTrue);

      final row = (await db.watchMessages(chat).first).single;
      expect(row.retracted, isTrue);
      expect(row.retractedAt, isNotNull);
      // The body is kept, not cleared: "deleted" and "we could not decrypt
      // this" must be distinguishable, and the person who sent it may still
      // want to read what they said.
      expect(row.body, 'the original text');
    });

    test('an un-retracted message has no retraction timestamp', () async {
      // The column must be able to answer "was this retracted". A SQL default
      // would fill it on every row and the answer would always be yes.
      final row = await store(stanzaId: id);
      expect(row.retracted, isFalse);
      expect(row.retractedAt, isNull);
    });

    test('is idempotent, and a replay does not un-retract', () async {
      await store(stanzaId: id);
      await db.markRetracted(id);
      final firstAt = (await db.watchMessages(chat).first).single.retractedAt;

      expect(await db.markRetracted(id), isFalse);
      final row = (await db.watchMessages(chat).first).single;
      expect(row.retracted, isTrue);
      expect(row.retractedAt, firstAt, reason: 'the time must not move');
    });

    test('an unknown id is a no-op, not a failure', () async {
      // A retraction for a message we never had is ordinary: the sender may
      // retract something before it arrives. Failing here would drop it and
      // then apply it to whatever arrived next.
      await store(stanzaId: id);
      expect(await db.markRetracted('some-other-id'), isFalse);
      expect((await db.watchMessages(chat).first).single.retracted, isFalse);
    });

    test('an empty id does nothing', () async {
      await store(stanzaId: id);
      expect(await db.markRetracted(''), isFalse);
    });

    test('one retraction does not touch its neighbours', () async {
      await store(stanzaId: 'a');
      await store(stanzaId: 'b');
      await db.markRetracted('a');
      final rows = await db.watchMessages(chat).first;
      expect(rows.firstWhere((m) => m.stanzaId == 'a').retracted, isTrue);
      expect(rows.firstWhere((m) => m.stanzaId == 'b').retracted, isFalse);
    });

    test('a group retraction is addressed by the room stanza-id', () async {
      await db.upsertChat(chat);
      await db.insertMessage(
        MessagesCompanion.insert(
          chatJid: chat,
          sender: 'me',
          stanzaId: const Value('origin-id-1'),
          roomStanzaId: const Value('room-stanza-1'),
          body: 'in the room',
          incoming: false,
        ),
      );
      expect(await db.markRetracted('room-stanza-1'), isTrue);
      final row = (await db.watchMessages(chat).first).single;
      expect(row.retracted, isTrue);
      expect(row.stanzaId, 'origin-id-1');
      expect(row.retractedBy, isEmpty);
    });

    test('a moderation records the moderator nick', () async {
      await store(stanzaId: id, incoming: true);
      expect(await db.markRetracted(id, by: 'mod'), isTrue);
      final row = (await db.watchMessages(chat).first).single;
      expect(row.retracted, isTrue);
      expect(row.retractedBy, 'mod');
    });
  });

  group('correction', () {
    test('replaces the body and marks it edited', () async {
      await store(stanzaId: id);
      await db.applyCorrection(
        chatJid: chat,
        targetId: id,
        body: 'the corrected text',
        encMode: 'OM',
      );
      final row = (await db.watchMessages(chat).first).single;
      expect(row.body, 'the corrected text');
      expect(row.editedAt, isNotNull);
    });

    test('an uncorrected message says so by having no timestamp', () async {
      // A boolean cannot tell "not edited" from "edited, and the flag was lost
      // in a migration".
      final row = await store(stanzaId: id);
      expect(row.editedAt, isNull);
    });

    test('arriving before the original is held, not shown twice', () async {
      // Order is not ours to choose: a correction can legitimately arrive
      // first. Showing the correction as a message of its own would put the
      // same text on screen twice — once stale, once correct.
      await db.applyCorrection(
        chatJid: chat,
        targetId: id,
        body: 'the corrected text',
        encMode: 'OM',
      );
      expect(await db.pendingCorrection(id), isNotNull);
      expect(await db.watchMessages(chat).first, isEmpty);

      await store(stanzaId: id, body: 'the original text');

      final rows = await db.watchMessages(chat).first;
      expect(rows, hasLength(1), reason: 'the correction is not a message');
      expect(rows.single.body, 'the corrected text');
      expect(rows.single.editedAt, isNotNull);
      // Consumed: a held correction that is never dropped would be applied
      // again to some later message with a recycled id.
      expect(await db.pendingCorrection(id), isNull);
    });

    test('a held correction keeps the sender\'s declared track', () async {
      // An archived original carries no EME, so applying it would report "no
      // encryption" for a message the sender told us was encrypted.
      await db.applyCorrection(
        chatJid: chat,
        targetId: id,
        body: 'the corrected text',
        encMode: 'OM',
      );
      await store(stanzaId: id, body: 'the original text', incoming: true);
      expect((await db.watchMessages(chat).first).single.encMode, 'OM');
    });

    test('a held correction supersedes a retraction of the same message', () async {
      // The sender un-deleted it by correcting it; a placeholder that outlives
      // its message is the wrong history.
      await store(stanzaId: id);
      await db.markRetracted(id);
      await db.applyCorrection(
        chatJid: chat,
        targetId: id,
        body: 'meant to say this',
        encMode: 'OM',
      );
      final row = (await db.watchMessages(chat).first).single;
      expect(row.retracted, isFalse);
      expect(row.body, 'meant to say this');
    });

    test('a correction of a known message adds no row', () async {
      await store(stanzaId: id);
      await db.applyCorrection(
        chatJid: chat,
        targetId: id,
        body: 'first fix',
        encMode: 'OM',
      );
      await db.applyCorrection(
        chatJid: chat,
        targetId: id,
        body: 'second fix',
        encMode: 'OM',
      );
      final rows = await db.watchMessages(chat).first;
      expect(rows, hasLength(1));
      expect(rows.single.body, 'second fix');
    });

    test('correcting a retracted message brings it back', () async {
      // The sender un-deleted it by correcting it; a placeholder that outlives
      // its message is the wrong history.
      await store(stanzaId: id);
      await db.markRetracted(id);
      await db.applyCorrection(
        chatJid: chat,
        targetId: id,
        body: 'meant to say this',
        encMode: 'OM',
      );
      final row = (await db.watchMessages(chat).first).single;
      expect(row.retracted, isFalse);
      expect(row.body, 'meant to say this');
    });

    test('an empty id is ignored', () async {
      await store(stanzaId: id);
      await db.applyCorrection(
        chatJid: chat,
        targetId: '',
        body: 'nowhere',
        encMode: 'OM',
      );
      final rows = await db.watchMessages(chat).first;
      expect(rows.single.body, 'the original text');
    });
  });
}
