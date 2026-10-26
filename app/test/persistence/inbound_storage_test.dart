// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
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

import 'package:resonchat/crypto/dual/track.dart';
import 'package:resonchat/domain/messages_service.dart';
import 'package:resonchat/persistence/database.dart';
import 'package:resonchat/translate/chat_auto_translate.dart';
import 'package:resonchat/ui/chats/chats_viewmodel.dart';
import 'package:resonchat/xmpp/inbound/inbound_message.dart';

void main() {
  group('bare JID normalisation', () {
    test('keeps a bare JID as-is', () {
      expect(bareJidOf('user@example.org'), 'user@example.org');
    });

    test('drops the resource, since the roster is per account', () {
      expect(bareJidOf('user@example.org/phone'), 'user@example.org');
      expect(bareJidOf('user@example.org/Some.Resource'), 'user@example.org');
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
      Track? track,
    }) => InboundMessage(
      from: JID.fromString(from),
      body: body,
      stanzaId: stanzaId,
      isCarbonCopy: carbon,
      track: track,
    );

    test('an ordinary message is stored once', () async {
      await MessagesService(db).storeInbound(message(body: 'hello'));
      await MessagesService(db).storeInbound(message(body: 'hello'));

      final rows = await db.watchMessages('peer@example.org').first;
      expect(rows.length, 1);
      expect(rows.single.body, 'hello');
      expect(rows.single.incoming, isTrue);
    });

    test('a carbon is not stored at all', () async {
      await MessagesService(db)
          .storeInbound(message(body: 'mine', stanzaId: 'c1', carbon: true));
      final rows = await db.watchMessages('peer@example.org').first;
      expect(rows, isEmpty);
      // The chat itself is still created, so the conversation appears.
      final chats = await db.watchChats().first;
      expect(chats.map((c) => c.jid), contains('peer@example.org'));
    });

    test('own archived outbound lands in the peer chat as outgoing', () async {
      await MessagesService(db).storeInbound(
        InboundMessage(
          from: JID.fromString('me@example.org/phone'),
          to: JID.fromString('peer@example.org'),
          body: 'sent while offline',
          stanzaId: 'out1',
          fromArchive: true,
          archiveTimestamp: DateTime.utc(2024, 1, 2),
        ),
        ownBare: 'me@example.org',
      );
      final rows = await db.watchMessages('peer@example.org').first;
      expect(rows.length, 1);
      expect(rows.single.body, 'sent while offline');
      expect(rows.single.incoming, isFalse);
      final self = await db.watchMessages('me@example.org').first;
      expect(self, isEmpty);
    });

    test(
      'an undecryptable message stores a placeholder, never ciphertext',
      () async {
        await MessagesService(db).storeInbound(
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
      },
    );

    // docs/10 §4.3. Before the track was recorded, every inbound message was
    // stored as 'none' — so a message from Conversations arrived in the UI
    // marked NO, telling the user their correspondent had sent in the clear.
    group('the stored track is what the sender declared', () {
      // Distinct stanza ids: these are separate conversations' worth of rows
      // sharing one database, and storeInbound deduplicates by id.
      Future<String?> storedTrack(String id, InboundMessage m) async {
        await MessagesService(db).storeInbound(m);
        final rows = await db.watchMessages('peer@example.org').first;
        return rows.firstWhere((r) => r.stanzaId == id).encMode;
      }

      test('a PQ message is stored as PQ', () async {
        expect(
          await storedTrack(
            'pq1',
            message(body: 'hi', stanzaId: 'pq1', track: Track.pq),
          ),
          EncModeToken.pq.wire,
        );
      });

      test(
        'a standard OMEMO message is stored as OM, not as plaintext',
        () async {
          expect(
            await storedTrack(
              'om1',
              message(body: 'hi', stanzaId: 'om1', track: Track.standard),
            ),
            EncModeToken.standard.wire,
          );
        },
      );

      test('a message with no declaration is stored as plaintext', () async {
        // No <encryption/> element means the sender made no claim. Calling
        // that OM because we happen to be able to decrypt it would be
        // inventing a fact about somebody else's client.
        expect(
          await storedTrack('plain1', message(body: 'hi', stanzaId: 'plain1')),
          EncModeToken.none.wire,
        );
      });
    });

    test('a message with no stanza id is still stored exactly once', () async {
      await MessagesService(db)
          .storeInbound(message(body: 'x', stanzaId: null));
      await MessagesService(db)
          .storeInbound(message(body: 'x', stanzaId: null));
      // Without an id we cannot deduplicate, so the second copy is kept —
      // but the first must not be lost, which is the part that matters.
      final rows = await db.watchMessages('peer@example.org').first;
      expect(rows, isNotEmpty);
      expect(rows.first.body, 'x');
    });

    test('the archived timestamp is preserved when present', () async {
      final when = DateTime(2026, 3, 4, 5, 6, 7);
      await MessagesService(db).storeInbound(
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

    const both = [
      InboundTranslation(lang: 'fr', text: 'bonjour', sourceLang: 'en'),
      InboundTranslation(lang: 'de', text: 'hallo', sourceLang: 'en'),
    ];

    test('an incoming message stores every translation', () async {
      await MessagesService(db).storeInbound(
        InboundMessage(
          from: JID.fromString('peer@example.org/phone'),
          body: 'hello',
          stanzaId: 'tr1',
          translations: both,
        ),
      );
      final rows = await db.watchMessageTranslations('peer@example.org').first;
      expect(rows.map((r) => r.lang).toSet(), {'fr', 'de'});
      expect(rows.map((r) => r.body).toSet(), {'bonjour', 'hallo'});
    });

    test('a copy we already have still keeps the translations', () async {
      final service = MessagesService(db);
      await service.storeInbound(
        InboundMessage(
          from: JID.fromString('peer@example.org/phone'),
          body: 'hello',
          stanzaId: 'tr2',
        ),
      );
      await service.storeInbound(
        InboundMessage(
          from: JID.fromString('peer@example.org/phone'),
          body: 'hello',
          stanzaId: 'tr2',
          translations: both,
        ),
      );
      final messages = await db.watchMessages('peer@example.org').first;
      expect(messages, hasLength(1));
      final rows = await db.watchMessageTranslations('peer@example.org').first;
      expect(rows.map((r) => r.lang).toSet(), {'fr', 'de'});
    });

    test('our own archived message stores its translations too', () async {
      await MessagesService(db).storeInbound(
        InboundMessage(
          from: JID.fromString('me@example.org/phone'),
          to: JID.fromString('peer@example.org'),
          body: 'hello',
          stanzaId: 'tr3',
          fromArchive: true,
          translations: both,
        ),
        ownBare: 'me@example.org',
      );
      final rows = await db.watchMessageTranslations('peer@example.org').first;
      expect(rows.map((r) => r.lang).toSet(), {'fr', 'de'});
    });

    test(
      'a carbon fills translations without storing another bubble',
      () async {
        final service = MessagesService(db);
        await service.storeInbound(
          InboundMessage(
            from: JID.fromString('me@example.org/phone'),
            to: JID.fromString('peer@example.org'),
            body: 'hello',
            stanzaId: 'tr4',
            fromArchive: true,
          ),
          ownBare: 'me@example.org',
        );
        await db.replaceMessageTranslations(
          chatJid: 'peer@example.org',
          stanzaId: 'tr4',
          rows: [
            (
              lang: kLocalOriginalLang,
              body: 'typed',
              sourceLang: '',
              engine: '',
            ),
          ],
        );
        await service.storeInbound(
          InboundMessage(
            from: JID.fromString('me@example.org/phone'),
            to: JID.fromString('peer@example.org'),
            body: 'hello',
            stanzaId: 'tr4',
            isCarbonCopy: true,
            translations: both,
          ),
          ownBare: 'me@example.org',
        );
        final messages = await db.watchMessages('peer@example.org').first;
        expect(messages, hasLength(1));
        final rows = await db
            .watchMessageTranslations('peer@example.org')
            .first;
        expect(rows.map((r) => r.lang).toSet(), {
          kLocalOriginalLang,
          'fr',
          'de',
        });
      },
    );

    test('a room reflection of our message keeps the translations', () async {
      const room = 'room@conference.example.org';
      await db.upsertChat(room, isGroup: true, mucNick: 'me');
      final service = MessagesService(db);
      await service.storeInbound(
        InboundMessage(
          from: JID.fromString('$room/me'),
          body: 'hello',
          stanzaId: 'tr5',
          type: 'groupchat',
        ),
      );
      await service.storeInbound(
        InboundMessage(
          from: JID.fromString('$room/me'),
          body: 'hello',
          stanzaId: 'tr5',
          type: 'groupchat',
          translations: both,
        ),
      );
      final messages = await db.watchMessages(room).first;
      expect(messages, hasLength(1));
      expect(messages.single.incoming, isFalse);
      final rows = await db.watchMessageTranslations(room).first;
      expect(rows.map((r) => r.lang).toSet(), {'fr', 'de'});
    });
  });
}
