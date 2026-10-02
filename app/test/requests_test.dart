// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Contact requests.
//
// The behaviour worth protecting is that a request is *recorded*, not granted.
// The old code approved every incoming request on arrival, which meant anyone
// could subscribe and start messaging the user with no say in it — and no test
// could have caught that, because "the request was approved" was the expected
// behaviour rather than the bug.

import 'package:drift/native.dart';
import 'package:test/test.dart';
import 'package:resonchat/store/database.dart';

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  group('recording', () {
    test('an incoming request is stored', () async {
      await db.addIncomingRequest('a@example.org');
      final rows = await db.watchSubscriptionRequests().first;
      expect(rows.single.jid, 'a@example.org');
      expect(rows.single.outgoing, isFalse);
    });

    test('a repeated request does not become two rows', () async {
      // The server re-sends the request, and a second row means the user is
      // asked to decide the same thing twice.
      await db.addIncomingRequest('a@example.org');
      await db.addIncomingRequest('a@example.org');
      expect(await db.watchSubscriptionRequests().first, hasLength(1));
    });

    test('incoming and outgoing are separate rows', () async {
      // The user has two kinds of waiting, and they need different answers.
      await db.addIncomingRequest('a@example.org');
      await db.addOutgoingRequest('a@example.org');
      final rows = await db.watchSubscriptionRequests().first;
      expect(rows, hasLength(2));
    });

    test('resolving one direction leaves the other', () async {
      await db.addIncomingRequest('a@example.org');
      await db.addOutgoingRequest('a@example.org');
      await db.resolveRequest('a@example.org', outgoing: false);
      final rows = await db.watchSubscriptionRequests().first;
      expect(rows.single.outgoing, isTrue);
    });
  });

  group('answering', () {
    test('an accepted request leaves the list', () async {
      await db.addIncomingRequest('a@example.org');
      await db.resolveRequest('a@example.org', outgoing: false);
      expect(await db.watchSubscriptionRequests().first, isEmpty);
    });

    test('a declined request leaves the list', () async {
      // A decline is an answer too. Leaving the row would mean the user is
      // asked again by someone they already turned away.
      await db.addIncomingRequest('a@example.org');
      await db.resolveRequest('a@example.org', outgoing: false);
      expect(await db.watchSubscriptionRequests().first, isEmpty);
    });

    test('answering something never asked leaves nothing behind', () async {
      await db.resolveRequest('never@example.org', outgoing: false);
      expect(await db.watchSubscriptionRequests().first, isEmpty);
    });

    test('answering twice is harmless', () async {
      await db.addIncomingRequest('a@example.org');
      await db.resolveRequest('a@example.org', outgoing: false);
      await db.resolveRequest('a@example.org', outgoing: false);
      expect(await db.watchSubscriptionRequests().first, isEmpty);
    });

    test('cancelling an outgoing request leaves the list', () async {
      await db.addOutgoingRequest('a@example.org');
      await db.resolveRequest('a@example.org', outgoing: true);
      expect(await db.watchSubscriptionRequests().first, isEmpty);
    });
  });
}
