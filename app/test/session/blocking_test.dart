// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Blocking (XEP-0191).
//
// The guarantee under test is narrow and the tests are narrow with it:
// blocking stops *us* from opening, storing and acknowledging. It does not stop
// the server routing the messages, and nothing here pretends otherwise.
//
// The test that matters most is the first one: that the stanza is cancelled
// **before** moxxmpp's OMEMO handler runs. A check placed after decryption
// would pass every other test in this file and still be reading the letters of
// someone the user blocked.

import 'package:drift/native.dart';
import 'package:moxxmpp/moxxmpp.dart';
import 'package:test/test.dart';

import 'package:resonchat/persistence/database.dart';
import 'package:resonchat/xmpp/blocked_inbound.dart';
import 'package:resonchat/xmpp/blocking.dart';

void main() {
  group('the guarantee', () {
    test('a blocked contact has nothing decrypted', () {
      final blocked = {'bad@example.org'};
      expect(mayDecrypt(blocked, 'bad@example.org'), isFalse);
      expect(mayDecrypt(blocked, 'good@example.org'), isTrue);
    });

    test('and nothing acknowledged', () {
      // Separate from decryption on purpose: not decrypting is about our keys,
      // not acknowledging is about telling a blocked sender that somebody is
      // reading. Coupling them means one of them ends up unenforced.
      final blocked = {'bad@example.org'};
      expect(mayAcknowledge(blocked, 'bad@example.org'), isFalse);
      expect(mayAcknowledge(blocked, 'good@example.org'), isTrue);
    });

    test('and nothing sent without an override', () {
      final blocked = {'bad@example.org'};
      expect(maySendWithoutOverride(blocked, 'bad@example.org'), isFalse);
      expect(maySendWithoutOverride(blocked, 'good@example.org'), isTrue);
    });

    test('an empty block list blocks nothing', () {
      // A bug that made an empty list read as "block everyone" would look
      // exactly like working software until someone tested a fresh install.
      expect(mayDecrypt(const {}, 'anyone@example.org'), isTrue);
    });
  });

  group('the stanza handler', () {
    Future<StanzaHandlerData> run(Stanza stanza, Set<String> blocked) {
      final manager = BlockedInboundManager(() => blocked, (_) {});
      final handler = manager.getIncomingPreStanzaHandlers().single;
      return handler.callback(
        stanza,
        StanzaHandlerData(false, false, stanza, TypedMap()),
      );
    }

    Stanza messageFrom(String jid) => Stanza.message(
      from: jid,
      to: 'me@example.org/phone',
      id: 'm1',
      type: 'chat',
    );

    test('cancels and skips, so nothing downstream can open it', () async {
      // `cancel` alone stops the remaining pre-handlers but the incoming
      // handlers still run, and MessageManager would emit an event for a
      // message nothing decrypted. `skip` is what actually stops it.
      final state = await run(messageFrom('bad@example.org'), {
        'bad@example.org',
      });
      expect(state.cancel, isTrue);
      expect(state.skip, isTrue);
    });

    test('runs ahead of the OMEMO handler', () {
      // The OMEMO handler decrypts. A handler that runs after it has already
      // used the keys, and the guarantee is gone however the rest reads.
      final manager = BlockedInboundManager(() => const {}, (_) {});
      final priority = manager.getIncomingPreStanzaHandlers().single.priority;
      // moxxmpp's OmemoManager registers its incoming pre-handler at 0.
      expect(priority, greaterThan(0));
    });

    test('leaves everyone else alone', () async {
      final state = await run(messageFrom('good@example.org'), {
        'bad@example.org',
      });
      expect(state.cancel, isFalse);
      expect(state.skip, isFalse);
    });

    test('matches on the bare JID, not the resource', () async {
      // Blocking is about a person. Blocking `bad@example.org/phone` and being
      // let through by `bad@example.org/laptop` would be no protection at all.
      final state = await run(messageFrom('bad@example.org/phone'), {
        'bad@example.org',
      });
      expect(state.skip, isTrue);
    });

    test('reports the drop so the UI can say it worked', () async {
      final dropped = <JID>[];
      final manager = BlockedInboundManager(
        () => {'bad@example.org'},
        dropped.add,
      );
      await manager.getIncomingPreStanzaHandlers().single.callback(
        messageFrom('bad@example.org/phone'),
        StanzaHandlerData(
          false,
          false,
          messageFrom('bad@example.org/phone'),
          TypedMap(),
        ),
      );
      expect(dropped.single.toBare().toString(), 'bad@example.org');
    });

    test('reads the list at call time, not at construction', () async {
      // The block list changes while the connection lives. A handler that
      // captured it would keep enforcing a block that was lifted.
      var blocked = <String>{'bad@example.org'};
      final manager = BlockedInboundManager(() => blocked, (_) {});
      final handler = manager.getIncomingPreStanzaHandlers().single;
      final stanza = messageFrom('bad@example.org/x');

      expect(
        (await handler.callback(
          stanza,
          StanzaHandlerData(false, false, stanza, TypedMap()),
        )).skip,
        isTrue,
      );
      blocked = {};
      expect(
        (await handler.callback(
          stanza,
          StanzaHandlerData(false, false, stanza, TypedMap()),
        )).skip,
        isFalse,
      );
    });
  });

  group('the stored list', () {
    late AppDatabase db;
    setUp(() => db = AppDatabase(NativeDatabase.memory()));
    tearDown(() => db.close());

    test('round trips', () async {
      expect(await isBlocked(db, 'a@example.org'), isFalse);
      await db.addBlocked('a@example.org');
      expect(await isBlocked(db, 'a@example.org'), isTrue);
      await db.removeBlocked('a@example.org');
      expect(await isBlocked(db, 'a@example.org'), isFalse);
    });

    test('adding twice does not throw', () async {
      await db.addBlocked('a@example.org');
      await db.addBlocked('a@example.org');
      expect(await blockedJids(db), {'a@example.org'});
    });

    test('a block push is idempotent', () async {
      await applyBlockPush(db, {'a@example.org'});
      await applyBlockPush(db, {'a@example.org'});
      expect(await blockedJids(db), {'a@example.org'});
    });

    test('an empty unblock push clears everything', () async {
      // XEP-0191 sends an empty item list to mean "unblock all". Treating it as
      // no change would leave this device enforcing blocks the user lifted on
      // another device — the exact case a server-side list exists to fix.
      await applyBlockPush(db, {'a@example.org', 'b@example.org'});
      await applyUnblockPush(db, const {});
      expect(await blockedJids(db), isEmpty);
    });

    test('a named unblock push clears only those', () async {
      await applyBlockPush(db, {'a@example.org', 'b@example.org'});
      await applyUnblockPush(db, {'a@example.org'});
      expect(await blockedJids(db), {'b@example.org'});
    });

    test('unblocking something not blocked is harmless', () async {
      await db.removeBlocked('never@example.org');
      expect(await blockedJids(db), isEmpty);
    });
  });
}
