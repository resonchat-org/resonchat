// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Drafts and pinned messages.
//
// Both are small features with one shared hazard: they are keyed on something
// that can be empty, and an empty key silently collapses into a shared one. A
// draft saved under '' is a draft for every conversation; a pin on a message
// with no addressable id pins nothing and can never be unpinned.

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:test/test.dart';

import 'package:resonchat/domain/messages_service.dart';
import 'package:resonchat/persistence/database.dart';

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  group('drafts', () {
    test('round trip', () async {
      expect(await db.draft('a@example.org'), isNull);
      await db.setDraft('a@example.org', 'half a thought');
      expect(await db.draft('a@example.org'), 'half a thought');
    });

    test('are per conversation', () async {
      // A draft saved under the wrong key is a draft for every conversation,
      // and the user finds someone else's half-sentence in their own box.
      await db.setDraft('a@example.org', 'about you');
      expect(await db.draft('b@example.org'), isNull);
    });

    test('an empty draft is deleted, not stored as empty', () async {
      // A row of empty strings is a list of conversations that once had a
      // draft, which is not a thing.
      await db.setDraft('a@example.org', 'something');
      await db.setDraft('a@example.org', '');
      expect(await db.draft('a@example.org'), isNull);
      expect(await db.metaValue('draft:a@example.org'), isNull);
    });

    test('clearing with null works the same way', () async {
      await db.setDraft('a@example.org', 'something');
      await db.setDraft('a@example.org', null);
      expect(await db.draft('a@example.org'), isNull);
    });

    test('whitespace alone is not a draft', () async {
      await db.setDraft('a@example.org', '   \n  ');
      expect(await db.draft('a@example.org'), isNull);
    });

    test('the text is preserved exactly, newlines and all', () async {
      // Trimmed only to decide whether it counts; what comes back is what the
      // user typed, because a draft that silently reformats their half-written
      // sentence is a draft that lies.
      const text = 'line one\nline two  \n\nline four';
      await db.setDraft('a@example.org', text);
      expect(await db.draft('a@example.org'), text);
    });
  });

  group('pinned messages', () {
    Future<void> seed(String stanzaId) async {
      await db.upsertChat('a@example.org');
      await db.insertMessageRow(
        MessagesCompanion.insert(
          chatJid: 'a@example.org',
          sender: 'a@example.org/x',
          stanzaId: Value(stanzaId),
          body: 'body $stanzaId',
          incoming: true,
        ),
      );
    }

    test('pinning and unpinning', () async {
      await seed('m1');
      expect(await db.isPinned('a@example.org', 'm1'), isFalse);
      await db.togglePinned('a@example.org', 'm1');
      expect(await db.isPinned('a@example.org', 'm1'), isTrue);
      await db.togglePinned('a@example.org', 'm1');
      expect(await db.isPinned('a@example.org', 'm1'), isFalse);
    });

    test('a message with no addressable id can never be pinned', () async {
      // Pinning nothing is worse than not offering the action: the entry
      // appears to have worked and there is nothing to unpin.
      await db.togglePinned('a@example.org', '');
      expect(await db.watchPinned('a@example.org').first, isEmpty);
    });

    test('are per conversation', () async {
      await db.upsertChat('a@example.org');
      await db.upsertChat('b@example.org');
      await db.togglePinned('a@example.org', 'm1');
      expect(await db.watchPinned('b@example.org').first, isEmpty);
      expect(await db.watchPinned('a@example.org').first, ['m1']);
    });

    test('the most recently pinned comes first', () async {
      await db.upsertChat('a@example.org');
      await db.togglePinned('a@example.org', 'm1');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await db.togglePinned('a@example.org', 'm2');
      // The one the user just pinned is the one they are looking for.
      expect(await db.watchPinned('a@example.org').first, ['m2', 'm1']);
    });

    test('a pinned message that is deleted still reads as pinned', () async {
      // Deleting a message does not unpin it. The pin is about "this is the one
      // that matters"; losing the pointer silently would make the user's own
      // choice evaporate because of somebody else's delete.
      await seed('m1');
      await db.togglePinned('a@example.org', 'm1');
      await MessagesService(db).markRetracted('m1');
      expect(await db.watchPinned('a@example.org').first, ['m1']);
    });
  });
}
