// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Where the user's protocol choice is stored (docs/10 §3).
//
// The behaviour worth protecting is the boring half of a security setting:
// that a choice nobody made is distinguishable from a choice of "no
// encryption", and that a fresh install cannot inherit plaintext by accident.

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:test/test.dart';

import 'package:resonchat/crypto/dual/track.dart';
import 'package:resonchat/persistence/database.dart';

/// Mirrors what the settings UI does when the track changes.
Future<void> setTrackForTest(
  AppDatabase db,
  String chatJid,
  Track? track,
) async {
  await db.setTrackOverride(chatJid, track);
  await db.clearPlaintextAcknowledgement(chatJid);
}

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  group('stored tokens', () {
    test('round-trip', () {
      for (final track in Track.values) {
        expect(Track.fromStored(track.stored), track);
      }
    });

    test('the token is what the user reads under the message', () {
      // A stored value the user could recognise makes a hand-edited or
      // restored database debuggable rather than mysterious.
      expect(Track.pq.stored, 'O2');
      expect(Track.standard.stored, 'OM');
      expect(Track.none.stored, 'NO');
    });

    test('older spellings still resolve', () {
      // Without this, every conversation stored before the rename silently
      // falls back to the global default.
      expect(Track.fromStored('pqOmemo'), Track.pq);
      expect(Track.fromStored('standardOmemo'), Track.standard);
    });

    test('case does not matter', () {
      // A user or a script that hand-edits the setting should not be punished
      // for the case; this is a label, not a wire format.
      expect(Track.fromStored('po'), Track.pq);
      expect(Track.fromStored('Po'), Track.pq);
    });

    test('an unrecognised value is not silently plaintext', () {
      // Returning null lets the caller choose the safe default; returning
      // Track.none here would send messages in the clear because of a typo.
      expect(Track.fromStored('encrypted'), isNull);
      expect(Track.fromStored(''), isNull);
      // Trailing whitespace is a real thing a hand-edit produces, and it must
      // not resolve to "the strongest available" by accident either.
      expect(Track.fromStored('PO '), isNull);
    });
  });

  group('per-conversation override', () {
    test('a conversation nobody chose a track for has no override', () async {
      await db.upsertChat('bob@example.org');
      expect(await db.trackOverride('bob@example.org'), isNull);
    });

    test('no override is distinguishable from "no encryption"', () async {
      await db.upsertChat('bob@example.org');
      await db.setTrackOverride('bob@example.org', Track.pq);
      await db.setTrackOverride('bob@example.org', null);

      // The important one: clearing an override must not read back as a
      // deliberate choice of plaintext. Both are "Track.none" only if we
      // conflate them, and conflating them is how a chat quietly starts
      // sending in the clear.
      expect(await db.trackOverride('bob@example.org'), isNull);
    });

    test('set and clear', () async {
      await db.upsertChat('bob@example.org');
      for (final track in Track.values) {
        await db.setTrackOverride('bob@example.org', track);
        expect(await db.trackOverride('bob@example.org'), track);
      }
      await db.setTrackOverride('bob@example.org', null);
      expect(await db.trackOverride('bob@example.org'), isNull);
    });

    test('a conversation with no row yet can still be pinned', () async {
      // The settings UI offers a track for any chat the user can see,
      // including one that has no messages and therefore no row yet.
      await db.setTrackOverride('new@example.org', Track.standard);
      expect(await db.trackOverride('new@example.org'), Track.standard);
      // And the row it created must be a real chat, so the choice survives
      // being read back after a restart.
      expect(
        (await db.watchChats().first).map((c) => c.jid),
        contains('new@example.org'),
      );
    });

    test('an override does not leak into a different conversation', () async {
      await db.upsertChat('a@example.org');
      await db.upsertChat('b@example.org');
      await db.setTrackOverride('a@example.org', Track.none);
      expect(await db.trackOverride('b@example.org'), isNull);
    });

    test('receiving a message does not wipe the choice', () async {
      // Every inbound message calls upsertChat. If that insert does not carry
      // track_override forward, the user's protocol choice is silently reset
      // to the global default by ordinary use — and to plaintext, if the
      // default is that.
      await db.upsertChat('bob@example.org');
      await db.setTrackOverride('bob@example.org', Track.none);
      await db.upsertChat('bob@example.org');
      expect(await db.trackOverride('bob@example.org'), Track.none);

      await db.insertMessageRow(
        MessagesCompanion(
          chatJid: const Value('bob@example.org'),
          sender: const Value('bob@example.org'),
          body: const Value('hi'),
          incoming: const Value(true),
        ),
      );
      expect(await db.trackOverride('bob@example.org'), Track.none);
    });

    test('a legacy row without the column reads as no override', () {
      // Migration v2 -> v3 backfills the column with ''. Such a row means
      // "never chosen", which is what it means.
      expect(Track.fromStored(''), isNull);
    });
  });

  group('the plaintext warning is remembered per conversation', () {
    // docs/10 §11 #7. A warning on every message is a warning nobody reads,
    // and the message it would have covered is exactly the one that goes out
    // in the clear unread.
    test('a fresh conversation has not acknowledged it', () async {
      expect(await db.plaintextAcknowledged('bob@example.org'), isFalse);
    });

    test('acknowledging silences it, and only for that conversation', () async {
      await db.acknowledgePlaintext('bob@example.org');
      expect(await db.plaintextAcknowledged('bob@example.org'), isTrue);
      expect(await db.plaintextAcknowledged('carol@example.org'), isFalse);
    });

    test('it can be cleared, which is what switching away re-arms', () async {
      await db.acknowledgePlaintext('bob@example.org');
      await db.clearPlaintextAcknowledgement('bob@example.org');
      expect(await db.plaintextAcknowledged('bob@example.org'), isFalse);
    });

    test('a changed track re-arms the warning', () async {
      // Returning to plaintext is the transition worth a fresh confirmation:
      // the circumstances that led away from it are usually why one came back.
      await db.acknowledgePlaintext('bob@example.org');
      await setTrackForTest(db, 'bob@example.org', Track.standard);
      expect(await db.plaintextAcknowledged('bob@example.org'), isFalse);
    });
  });

  group('messages are unaffected by the new column', () {
    test('a stored track for an old message still resolves', () async {
      // The rename lives in the parser, not in a data migration: a message's
      // track is a fact about the past and does not change because we
      // renamed the vocabulary.
      await db.upsertChat('bob@example.org');
      await db.insertMessageRow(
        MessagesCompanion(
          chatJid: const Value('bob@example.org'),
          sender: const Value('me'),
          body: const Value('hi'),
          encMode: const Value('standardOmemo'),
          incoming: const Value(false),
        ),
      );
      final row = await (db.select(db.messages)).getSingle();
      expect(EncModeToken.parse(row.encMode).track, Track.standard);
    });
  });
}
