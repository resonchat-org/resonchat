// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:moxxmpp/moxxmpp.dart';
import 'package:test/test.dart';

import 'package:resonchat/crypto/dual/track.dart';
import 'package:resonchat/crypto/omemo2/sce.dart';
import 'package:resonchat/domain/messages_service.dart';
import 'package:resonchat/persistence/database.dart';
import 'package:resonchat/xmpp/chat/peertrans.dart';
import 'package:resonchat/xmpp/chat/peertrans_apply.dart';
import 'package:resonchat/xmpp/inbound/inbound_message.dart';

void main() {
  group('PeerTransData.fromStanza', () {
    test('requires peertrans + reply + langtrans destination body', () {
      final ok = PeerTransData.fromStanza(
        XMLNode.fromString('''
<message>
  <body xml:lang='zh'>> Good morning

早上好</body>
  <x xmlns='urn:xmpp:langtrans'>
    <translation destination_lang='zh' source_lang='en' engine='DeepL'/>
  </x>
  <reply xmlns='urn:xmpp:reply:0' id='S1'/>
  <fallback xmlns='urn:xmpp:fallback:0' for='urn:xmpp:reply:0'>
    <body start='0' end='16'/>
  </fallback>
  <peertrans xmlns='urn:resonchat:peertrans:0' priority='3'/>
</message>
'''),
      );
      expect(ok, isNotNull);
      expect(ok!.parentId, 'S1');
      expect(ok.priority, 3);
      expect(ok.bodies, hasLength(1));
      expect(ok.bodies.single.lang, 'zh');
      expect(ok.bodies.single.text, '早上好');
      expect(ok.bodies.single.engine, 'DeepL');
    });

    test('marker+reply without langtrans still suppresses (empty bodies)', () {
      final parsed = PeerTransData.fromStanza(
        XMLNode.fromString('''
<message>
  <body xml:lang='zh'>早上好</body>
  <reply xmlns='urn:xmpp:reply:0' id='S1'/>
  <peertrans xmlns='urn:resonchat:peertrans:0' priority='3'/>
</message>
'''),
      );
      expect(parsed, isNotNull);
      expect(parsed!.parentId, 'S1');
      expect(parsed.bodies, isEmpty);
    });

    test('recovers body when xml:lang stripped but langtrans hint present', () {
      final parsed = PeerTransData.fromStanza(
        XMLNode.fromString('''
<message>
  <body>> Good morning

早上好</body>
  <x xmlns='urn:xmpp:langtrans'>
    <translation destination_lang='zh' source_lang='en' engine='resonbot-demo'/>
  </x>
  <reply xmlns='urn:xmpp:reply:0' id='S1'/>
  <fallback xmlns='urn:xmpp:fallback:0' for='urn:xmpp:reply:0'>
    <body start='0' end='15'/>
  </fallback>
  <peertrans xmlns='urn:resonchat:peertrans:0' priority='3'/>
</message>
'''),
      );
      expect(parsed, isNotNull);
      expect(parsed!.bodies, hasLength(1));
      expect(parsed.bodies.single.lang, 'zh');
      expect(parsed.bodies.single.text, '早上好');
    });

    test('clamps invalid priority to 0', () {
      final parsed = PeerTransData.fromStanza(
        XMLNode.fromString('''
<message>
  <body xml:lang='zh'>早上好</body>
  <x xmlns='urn:xmpp:langtrans'>
    <translation destination_lang='zh' source_lang='en'/>
  </x>
  <reply xmlns='urn:xmpp:reply:0' id='S1'/>
  <peertrans xmlns='urn:resonchat:peertrans:0' priority='99'/>
</message>
'''),
      )!;
      expect(parsed.priority, 0);
    });
  });

  group('source label', () {
    test('keeps MUC nick; shortens bare JID to localpart', () {
      expect(peertransSourceLabel('alice'), 'alice');
      expect(peertransSourceLabel('bot@example.com'), 'bot');
      expect(peertransSourceLabel('  '), '');
    });
  });

  group('ranking', () {
    test('higher priority wins; tie goes to earliest', () {
      final a = PeerTransRanked(
        priority: 3,
        sender: 'bot',
        supplementId: 'b',
        timestamp: DateTime.utc(2026, 1, 2),
        body: 'later',
      );
      final b = PeerTransRanked(
        priority: 3,
        sender: 'alice',
        supplementId: 'a',
        timestamp: DateTime.utc(2026, 1, 1),
        body: 'earlier',
      );
      final c = PeerTransRanked(
        priority: 5,
        sender: 'pro',
        supplementId: 'c',
        timestamp: DateTime.utc(2026, 1, 3),
        body: 'best',
      );
      expect(selectPeerTransWinner([a, b, c])!.body, 'best');
      expect(selectPeerTransWinner([a, b])!.body, 'earlier');
    });
  });

  group('crypto gates', () {
    test('plaintext parent accepts plaintext peertrans only', () {
      expect(
        peertransCryptoAllowsMerge(
          parentEncMode: EncModeToken.none.wire,
          peertransTrack: Track.none,
        ),
        isTrue,
      );
      expect(
        peertransCryptoAllowsMerge(
          parentEncMode: EncModeToken.none.wire,
          peertransTrack: Track.pq,
        ),
        isFalse,
      );
    });

    test(
      'PQ parent accepts PQ peertrans; standard parent has no peertrans',
      () {
        expect(
          peertransCryptoAllowsMerge(
            parentEncMode: EncModeToken.pq.wire,
            peertransTrack: Track.pq,
          ),
          isTrue,
        );
        expect(
          peertransCryptoAllowsMerge(
            parentEncMode: EncModeToken.standard.wire,
            peertransTrack: Track.none,
          ),
          isFalse,
        );
        expect(
          peertransCryptoAllowsMerge(
            parentEncMode: EncModeToken.standard.wire,
            peertransTrack: Track.pq,
          ),
          isFalse,
        );
      },
    );
  });

  group('SCE reinject', () {
    test('parses content children from an envelope', () {
      final kids = sceContentChildren('''
<envelope xmlns='urn:xmpp:sce:1'>
  <content>
    <body xml:lang='zh'>早上好</body>
    <x xmlns='urn:xmpp:langtrans'>
      <translation destination_lang='zh' source_lang='en'/>
    </x>
    <peertrans xmlns='urn:resonchat:peertrans:0' priority='3'/>
  </content>
</envelope>
''');
      expect(kids, isNotNull);
      expect(kids!.map((c) => c.tag), containsAll(['body', 'x', 'peertrans']));
    });

    test('plain string is not SCE', () {
      expect(sceContentChildren('早上好'), isNull);
    });
  });

  group('store merge', () {
    late AppDatabase db;
    late MessagesService service;
    const chat = 'room@muc.example';

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      service = MessagesService(db);
    });
    tearDown(() => db.close());

    Future<void> insertParent() async {
      await db.upsertChat(chat, isGroup: true);
      await db.insertMessageRow(
        MessagesCompanion.insert(
          chatJid: chat,
          sender: 'room@muc.example/alice',
          stanzaId: const Value('a1'),
          roomStanzaId: const Value('S1'),
          body: 'Good morning',
          incoming: true,
          encMode: const Value('none'),
        ),
      );
    }

    InboundMessage peerTransMsg({
      required String supplementId,
      required int priority,
      required String text,
      String lang = 'zh',
      String sender = 'bot',
      DateTime? at,
    }) {
      return InboundMessage(
        from: JID.fromString('$chat/$sender'),
        type: 'groupchat',
        body: text,
        stanzaId: supplementId,
        originId: supplementId,
        track: Track.none,
        archiveTimestamp: at ?? DateTime.utc(2026, 1, 1),
        peerTrans: PeerTransData(
          priority: priority,
          bodies: [PeerTransLangBody(lang: lang, text: text, engine: 'DeepL')],
          parentId: 'S1',
        ),
      );
    }

    test('merges under parent and does not insert a bubble', () async {
      await insertParent();
      await service.storeInbound(
        peerTransMsg(supplementId: 'b1', priority: 3, text: '早上好'),
      );
      final bubbles = await (db.select(
        db.messages,
      )..where((m) => m.chatJid.equals(chat) & m.stanzaId.equals('b1'))).get();
      expect(bubbles, isEmpty);
      // UI keys translations by the parent's stored stanzaId (origin-id),
      // not the MUC room stanza-id that <reply id/> points at.
      final byParent = await (db.select(
        db.messageTranslations,
      )..where((t) => t.chatJid.equals(chat) & t.stanzaId.equals('a1'))).get();
      expect(byParent, hasLength(1));
      expect(byParent.single.body, '早上好');
      expect(byParent.single.lang, 'zh');
      expect(byParent.single.engine, 'DeepL');
      expect(byParent.single.by, 'bot');
      expect(
        await (db.select(db.messageTranslations)
              ..where((t) => t.chatJid.equals(chat) & t.stanzaId.equals('S1')))
            .get(),
        isEmpty,
      );
    });

    test('marker with empty bodies still inserts no bubble', () async {
      await insertParent();
      await service.storeInbound(
        InboundMessage(
          from: JID.fromString('$chat/bot'),
          type: 'groupchat',
          body: '早上好',
          stanzaId: 'b-empty',
          originId: 'b-empty',
          track: Track.none,
          archiveTimestamp: DateTime.utc(2026, 1, 1),
          peerTrans: const PeerTransData(
            priority: 3,
            bodies: [],
            parentId: 'S1',
          ),
        ),
      );
      expect(
        await (db.select(db.messages)..where(
              (m) => m.chatJid.equals(chat) & m.stanzaId.equals('b-empty'),
            ))
            .get(),
        isEmpty,
      );
    });

    test('higher priority replaces lower', () async {
      await insertParent();
      await service.storeInbound(
        peerTransMsg(
          supplementId: 'b1',
          priority: 3,
          text: '低',
          sender: 'bot1',
          at: DateTime.utc(2026, 1, 1),
        ),
      );
      await service.storeInbound(
        peerTransMsg(
          supplementId: 'b2',
          priority: 5,
          text: '高',
          sender: 'bot2',
          at: DateTime.utc(2026, 1, 2),
        ),
      );
      final byParent = await (db.select(
        db.messageTranslations,
      )..where((t) => t.chatJid.equals(chat) & t.stanzaId.equals('a1'))).get();
      expect(byParent.single.body, '高');
    });

    test('early peertrans flushes when parent arrives', () async {
      await db.upsertChat(chat, isGroup: true);
      await service.storeInbound(
        peerTransMsg(supplementId: 'b1', priority: 3, text: '早上好'),
      );
      expect(
        await (db.select(
          db.messageTranslations,
        )..where((t) => t.chatJid.equals(chat))).get(),
        isEmpty,
      );
      await service.storeInbound(
        InboundMessage(
          from: JID.fromString('$chat/alice'),
          type: 'groupchat',
          body: 'Good morning',
          stanzaId: 'a1',
          originId: 'a1',
          roomStanzaId: 'S1',
          track: Track.none,
          archiveTimestamp: DateTime.utc(2026, 1, 1),
        ),
      );
      final byParent = await (db.select(
        db.messageTranslations,
      )..where((t) => t.chatJid.equals(chat) & t.stanzaId.equals('a1'))).get();
      expect(byParent.single.body, '早上好');
    });

    test('admins-only drops non-admin senders', () async {
      await insertParent();
      await db.setPeertransAdminsOnly(true);
      await service.storeInbound(
        peerTransMsg(supplementId: 'b1', priority: 3, text: '丢'),
        senderAffiliation: 'member',
      );
      expect(
        await (db.select(
          db.messageTranslations,
        )..where((t) => t.chatJid.equals(chat))).get(),
        isEmpty,
      );
      await service.storeInbound(
        peerTransMsg(
          supplementId: 'b2',
          priority: 3,
          text: '留',
          sender: 'adminbot',
        ),
        senderAffiliation: 'admin',
      );
      final byParent = await (db.select(
        db.messageTranslations,
      )..where((t) => t.chatJid.equals(chat) & t.stanzaId.equals('a1'))).get();
      expect(byParent.single.body, '留');
    });
  });
}
