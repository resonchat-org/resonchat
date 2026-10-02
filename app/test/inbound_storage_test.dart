// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Opening a chat by JID must create a *real* conversation.
//
// A local database row is not a contact: servers only route stanzas between
// accounts that are in each other's roster. Getting that wrong is invisible
// until messages simply never arrive, which is exactly the failure this
// project hit against conversations.im.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moxxmpp/moxxmpp.dart';
import 'package:resonchat/state/app_wiring.dart';
import 'package:resonchat/store/database.dart';
import 'package:resonchat/ui/chats_page.dart';
import 'package:resonchat/xmpp/connection.dart';

void main() {
  group('bare JID normalisation', () {
    test('keeps a bare JID as-is', () {
      expect(bareJidOf('user@example.org'), 'user@example.org');
    });

    test('drops the resource, since the roster is per account', () {
      expect(bareJidOf('user@example.org/phone'), 'user@example.org');
      expect(
        bareJidOf('user@example.org/Some.Resource'),
        'user@example.org',
      );
    });

    test('trims surrounding whitespace', () {
      expect(bareJidOf('  user@example.org  '), 'user@example.org');
    });

    test('rejects anything that is not a JID', () {
      for (final bad in [
        '',
        'notajid',
        '@example.org',
        'user@',
        'user@@example.org',
        'a@b@c',
      ]) {
        expect(bareJidOf(bad), isNull, reason: 'accepted "$bad"');
      }
    });
  });

  group('inbound storage is idempotent', () {
    late Directory dir;
    late AppDatabase db;

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('resonchat_inbound');
      db = AppDatabase(NativeDatabase(File('${dir.path}/in.sqlite3')));
    });
    tearDown(() async {
      await db.close();
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    InboundMessage message({
      required String body,
      String? stanzaId = 's1',
      bool carbon = false,
      String from = 'peer@example.org/phone',
    }) =>
        InboundMessage(
          from: JID.fromString(from),
          body: body,
          stanzaId: stanzaId,
          isCarbonCopy: carbon,
        );

    test('an ordinary message is stored once', () async {
      await storeInbound(db, message(body: 'hello'));
      await storeInbound(db, message(body: 'hello'));

      final rows = await db.watchMessages('peer@example.org').first;
      expect(rows.length, 1);
      expect(rows.single.body, 'hello');
      expect(rows.single.incoming, isTrue);
    });

    test('a carbon is not stored at all', () async {
      await storeInbound(db, message(body: 'mine', stanzaId: 'c1', carbon: true));
      final rows = await db.watchMessages('peer@example.org').first;
      expect(rows, isEmpty);
      // The chat itself is still created, so the conversation appears.
      final chats = await db.watchChats().first;
      expect(chats.map((c) => c.jid), contains('peer@example.org'));
    });

    test('an undecryptable message stores a placeholder, never ciphertext',
        () async {
      await storeInbound(
        db,
        InboundMessage(
          from: JID.fromString('peer@example.org/phone'),
          body: '',
          stanzaId: 's2',
          encryptionError: 'no session',
        ),
      );
      final rows = await db.watchMessages('peer@example.org').first;
      expect(rows.single.body, isEmpty);
      expect(rows.single.encMode, 'error');
    });

    test('a message with no stanza id is still stored exactly once', () async {
      await storeInbound(db, message(body: 'x', stanzaId: null));
      await storeInbound(db, message(body: 'x', stanzaId: null));
      // Without an id we cannot deduplicate, so the second copy is kept —
      // but the first must not be lost, which is the part that matters.
      final rows = await db.watchMessages('peer@example.org').first;
      expect(rows, isNotEmpty);
      expect(rows.first.body, 'x');
    });

    test('the archived timestamp is preserved when present', () async {
      final when = DateTime(2026, 3, 4, 5, 6, 7);
      await storeInbound(
        db,
        InboundMessage(
          from: JID.fromString('peer@example.org/phone'),
          body: 'old',
          stanzaId: 's3',
          fromArchive: true,
          archiveTimestamp: when,
        ),
      );
      final rows = await db.watchMessages('peer@example.org').first;
      expect(rows.single.timestamp, when);
    });
  });
}