// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Emoji reactions (XEP-0444).
//
// The behaviour worth protecting is the withdrawal. A reaction broadcast is a
// complete list from one reactor, so "I took my 👍 back" is an empty list — and
// any implementation that merges instead of replacing leaves the withdrawn
// reaction on the sender's screen forever, which no user can undo and no test
// that only checks "can I add one" would ever notice.

import 'package:drift/native.dart';
import 'package:test/test.dart';

import 'package:resonchat/domain/messages_service.dart';
import 'package:resonchat/persistence/database.dart';
import 'package:resonchat/xmpp/chat/reactions.dart';
import 'package:resonchat/xmpp/inbound/reaction_update.dart';

void main() {
  late AppDatabase db;
  late MessagesService messages;
  const me = 'me@example.org';
  const peer = 'peer@example.org';
  const target = 'origin-id-1';

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    messages = MessagesService(db);
  });
  tearDown(() => db.close());

  Future<void> react(String reactor, List<String> emojis) =>
      messages.storeReaction(
        ReactionUpdate(targetId: target, reactor: reactor, emojis: emojis),
      );

  group('a broadcast is a complete set', () {
    test('adding', () async {
      await react(peer, ['👍']);
      final groups = await reactionsFor(db, target, me);
      expect(groups.single.emoji, '👍');
      expect(groups.single.count, 1);
      expect(groups.single.mine, isFalse);
    });

    test('two reactors with the same emoji are two reactions', () async {
      await react(peer, ['👍']);
      await react('peer@phone', ['👍']);
      final groups = await reactionsFor(db, target, me);
      expect(groups.single.count, 2);
    });

    test('a later broadcast replaces the earlier one', () async {
      await react(peer, ['👍', '❤']);
      await react(peer, ['❤']);
      final groups = await reactionsFor(db, target, me);
      expect(groups.map((g) => g.emoji), ['❤']);
    });

    test('an empty list withdraws, and leaves nothing behind', () async {
      // The bug this whole file exists for: merging instead of replacing
      // leaves the withdrawn row on the sender's screen permanently.
      await react(peer, ['👍', '😂']);
      await react(peer, const []);
      expect(await db.allReactions(target), isEmpty);
      expect(await reactionsFor(db, target, me), isEmpty);
    });

    test('withdrawing one of several keeps the rest', () async {
      await react(peer, ['👍', '😂']);
      await react(peer, ['😂']);
      final groups = await reactionsFor(db, target, me);
      expect(groups.single.emoji, '😂');
    });

    test('a duplicate within one broadcast does not throw', () async {
      // Two identical rows would violate the primary key; a client bug or a
      // replayed stanza must not take the receiver down.
      await react(peer, ['👍', '👍']);
      final groups = await reactionsFor(db, target, me);
      expect(groups.single.count, 1);
    });
  });

  group('one reactor does not disturb another', () {
    test('withdrawing ours leaves theirs', () async {
      await react(peer, ['👍']);
      await react(me, ['👍']);
      await react(me, const []);
      final groups = await reactionsFor(db, target, me);
      expect(groups.single.count, 1);
      expect(groups.single.mine, isFalse);
    });

    test('and the chip knows it is not ours', () async {
      await react(peer, ['👍']);
      await react(me, ['😂']);
      final groups = await reactionsFor(db, target, me);
      expect(groups.firstWhere((g) => g.emoji == '👍').mine, isFalse);
      expect(groups.firstWhere((g) => g.emoji == '😂').mine, isTrue);
    });
  });

  group('chips are ordered for reading', () {
    test('the most-reacted leads', () async {
      await react('a@peer', ['😂']);
      await react('b@peer', ['😂']);
      await react('c@peer', ['😂']);
      await react('d@peer', ['👍']);
      final groups = await reactionsFor(db, target, me);
      expect(groups.first.emoji, '😂');
      expect(groups.first.count, 3);
      expect(groups.last.count, 1);
    });

    test('ties break on the emoji, so the order is stable', () async {
      // Otherwise the strip reorders on every rebuild, which reads as the
      // reactions flickering.
      await react(peer, ['👍', '😂']);
      final first = (await reactionsFor(
        db,
        target,
        me,
      )).map((g) => g.emoji).toList();
      final second = (await reactionsFor(
        db,
        target,
        me,
      )).map((g) => g.emoji).toList();
      expect(first, second);
    });
  });

  group('isolation between messages', () {
    test('a reaction lands on its target only', () async {
      await messages.storeReaction(
        ReactionUpdate(targetId: 'origin-id-1', reactor: peer, emojis: ['👍']),
      );
      await messages.storeReaction(
        ReactionUpdate(targetId: 'origin-id-2', reactor: peer, emojis: ['😂']),
      );
      expect((await reactionsFor(db, 'origin-id-1', me)).single.emoji, '👍');
      expect((await reactionsFor(db, 'origin-id-2', me)).single.emoji, '😂');
    });

    test('an unaddressed message has no chips', () async {
      // The bubble draws none rather than showing chips nobody could add to.
      expect(await reactionsFor(db, '', me), isEmpty);
    });
  });

  group('the quick set', () {
    test('defaults avoid the text-presentation heart', () {
      // Linux draws U+2764 black beside coloured emoji; the heart slot is 💗.
      expect(kQuickReactions, isNot(contains('❤')));
      expect(kQuickReactions, isNot(contains('❤️')));
    });

    test('and they are distinct', () {
      expect(kQuickReactions.toSet(), hasLength(kQuickReactions.length));
    });
  });
}
