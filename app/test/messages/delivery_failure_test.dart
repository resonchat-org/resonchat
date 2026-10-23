// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// A message the server refused must not look sent.
//
// Discovered by measurement: conversations.im answers every stanza outside a
// mutual subscription with
//
//   <error type='auth'><forbidden/>
//   <text>Access denied by service policy</text></error>
//
// which used to be indistinguishable from a delivered message. These tests
// pin the two halves: the failure is recorded against the right stanza, and
// the contact state is described honestly.

import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moxxmpp/moxxmpp.dart';

import 'package:resonchat/persistence/database.dart';
import 'package:resonchat/state/providers.dart';
import 'package:resonchat/xmpp/connection.dart';

void main() {
  group('describeStanzaError keeps the server\'s reason', () {
    test('a generic condition keeps type, condition and text', () {
      expect(
        describeStanzaError(
          GenericStanzaError(
            type: 'auth',
            code: '',
            text: 'Access denied by service policy',
            condition: 'forbidden',
          ),
        ),
        'auth/forbidden: Access denied by service policy',
      );
    });

    test('a condition without text still names itself', () {
      expect(
        describeStanzaError(
          GenericStanzaError(
            type: 'cancel',
            code: '404',
            text: '',
            condition: 'item-not-found',
          ),
        ),
        'cancel/item-not-found',
      );
    });

    test('a modelled error falls back to its own rendering', () {
      expect(describeStanzaError(ServiceUnavailableError()), isNotEmpty);
    });
  });

  group('delivery failure is recorded against the right message', () {
    late Directory dir;
    late AppDatabase db;

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('resonchat_delivery');
      db = AppDatabase(NativeDatabase(File('${dir.path}/test.sqlite3')));
      await db.upsertChat('peer@example.org');
    });
    tearDown(() async {
      await db.close();
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    test('the refusal is written onto the sent message', () async {
      await db.insertMessageRow(
        MessagesCompanion(
          chatJid: const Value('peer@example.org'),
          sender: const Value('me'),
          stanzaId: const Value('stanza-1'),
          body: const Value('hello'),
          incoming: const Value(false),
        ),
      );

      final updated = await db.markDeliveryFailure(
        'stanza-1',
        'auth/forbidden: nope',
      );
      expect(updated, isTrue);

      final rows = await db.watchMessages('peer@example.org').first;
      expect(rows.single.deliveryError, 'auth/forbidden: nope');
    });

    test('an unrelated stanza id changes nothing', () async {
      await db.insertMessageRow(
        MessagesCompanion(
          chatJid: const Value('peer@example.org'),
          sender: const Value('me'),
          stanzaId: const Value('stanza-1'),
          body: const Value('hello'),
          incoming: const Value(false),
        ),
      );

      expect(await db.markDeliveryFailure('other', 'auth/forbidden'), isFalse);
      final rows = await db.watchMessages('peer@example.org').first;
      expect(rows.single.deliveryError, isEmpty);
    });

    test(
      'an empty stanza id is ignored rather than matching every row',
      () async {
        await db.insertMessageRow(
          MessagesCompanion(
            chatJid: const Value('peer@example.org'),
            sender: const Value('me'),
            stanzaId: const Value(''),
            body: const Value('hello'),
            incoming: const Value(false),
          ),
        );
        expect(await db.markDeliveryFailure('', 'auth/forbidden'), isFalse);
      },
    );

    test('a fresh message is not marked as failed', () async {
      await db.insertMessageRow(
        MessagesCompanion(
          chatJid: const Value('peer@example.org'),
          sender: const Value('me'),
          body: const Value('hello'),
          incoming: const Value(false),
        ),
      );
      final rows = await db.watchMessages('peer@example.org').first;
      expect(rows.single.deliveryError, isEmpty);
      expect(rows.single.delivered, isFalse);
    });
  });

  group('contact state is described honestly', () {
    test('only "both" counts as mutual', () {
      expect(
        const ContactState(subscription: 'both', asked: false).isMutual,
        isTrue,
      );
      for (final s in ['none', 'to', 'from']) {
        expect(
          ContactState(subscription: s, asked: false).isMutual,
          isFalse,
          reason: '$s is not mutual',
        );
      }
    });

    test('a pending request is stated as pending, not as a failure', () {
      expect(
        const ContactState(subscription: 'from', asked: true).summary,
        contains('pending'),
      );
      // RFC 6121: `from` means they are subscribed to us, so they see us.
      expect(
        const ContactState(subscription: 'from', asked: false).summary,
        contains('you cannot see them'),
      );
      // `to` means we are subscribed to them, so we see them.
      expect(
        const ContactState(subscription: 'to', asked: false).summary,
        contains('they cannot see you'),
      );
      expect(
        const ContactState(subscription: 'none', asked: false).summary,
        'not a contact',
      );
    });
  });

  group('a delivery failure carries what the UI needs', () {
    test('it names the stanza, the peer and the reason', () {
      final failure = DeliveryFailure(
        stanzaId: 'abc',
        from: JID.fromString('peer@example.org'),
        reason: 'auth/forbidden',
      );
      expect(failure.stanzaId, 'abc');
      expect(failure.from.toBare().toString(), 'peer@example.org');
      expect(failure.reason, 'auth/forbidden');
    });

    test('toString is readable in a log', () {
      final failure = DeliveryFailure(
        stanzaId: 'abc',
        from: JID.fromString('peer@example.org'),
        reason: 'auth/forbidden: Access denied by service policy',
      );
      expect(failure.toString(), contains('abc'));
      expect(failure.toString(), contains('Access denied by service policy'));
    });
  });

  group('only a content stanza can fail delivery', () {
    MessageEvent bounce({String? body, bool encrypted = false}) => MessageEvent(
      JID.fromString('peer@example.org'),
      JID.fromString('me@example.org'),
      encrypted,
      TypedMap<StanzaHandlerExtension>.fromList([
        if (body != null) MessageBodyData(body),
      ]),
      id: 'm1',
      type: 'error',
    );

    test('a body counts', () {
      expect(carriesMessageContent(bounce(body: 'hello')), isTrue);
    });

    test('an encrypted stanza counts', () {
      expect(carriesMessageContent(bounce(encrypted: true)), isTrue);
    });

    test('a bounced chat state does not', () {
      // Servers echo <composing/> back with the peer as `from` and an
      // <error/>; treating that as a message failure is what invented the
      // "not a mutual subscription" dialog for an offline contact.
      expect(carriesMessageContent(bounce()), isFalse);
    });
  });

  group('a cancelled send says why nothing went out', () {
    test('no usable device is named', () {
      expect(
        describeSendingCancellation(OmemoNotSupportedForContactException()),
        contains('no usable encryption device'),
      );
    });

    test('other encryption failures stay generic', () {
      expect(
        describeSendingCancellation(UnknownOmemoError()),
        contains('could not be encrypted'),
      );
      expect(describeSendingCancellation(null), startsWith('cancel'));
    });
  });
}
