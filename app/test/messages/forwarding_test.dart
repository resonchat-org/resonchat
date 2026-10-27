// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Forwarding: multi-select resend vs long-press XEP-0297.

import 'package:moxxmpp/moxxmpp.dart';
import 'package:test/test.dart';

import 'package:resonchat/crypto/dual/track.dart';
import 'package:resonchat/crypto/dual/track_resolver.dart';
import 'package:resonchat/xmpp/chat/forwarding.dart';
import 'package:resonchat/xmpp/connection.dart';
import 'package:resonchat/xmpp/inbound/forward_info.dart';
import 'package:resonchat/xmpp/inbound/inbound_mapper.dart';

/// A sender that records what it was asked to send (resend path).
class _Recorder {
  final calls = <({String wireBody, Track track})>[];
  int failAfter = 1 << 30;

  Future<SendOutcome> send(String wireBody, Track track) async {
    calls.add((wireBody: wireBody, track: track));
    if (calls.length > failAfter) {
      return const SendOutcome(
        stanzaId: null,
        track: Track.standard,
        blocked: TrackBlocked.pqUnavailable,
      );
    }
    return SendOutcome(stanzaId: 'stanza-${calls.length}', track: track);
  }
}

const _items = [
  ForwardItem(body: 'the first thing', chatJid: 'a@b.example'),
  ForwardItem(body: 'the second thing', chatJid: 'a@b.example'),
];

void main() {
  group('resend (multi-select)', () {
    test('each message quotes the original text', () async {
      final r = _Recorder();
      await runForward(items: _items, track: Track.standard, send: r.send);
      expect(r.calls.first.wireBody, contains('> the first thing'));
      expect(
        r.calls.first.wireBody,
        contains(forwardAttribution('a@b.example')),
      );
    });

    test('the attribution is not mixed into the quoted lines', () {
      expect(forwardAttribution('a@b.example'), startsWith('Forwarded from '));
      expect(forwardAttribution('a@b.example'), isNot(contains('>')));
      final wire = forwardWireBody(_items.first);
      expect(wire, isNot(contains('> Forwarded from')));
    });

    test('preformatted transcript is sent as-is', () async {
      final r = _Recorder();
      const text = '2024-01-01 12:00 - alice:\n> hello';
      await runForward(
        items: [
          const ForwardItem(
            body: text,
            chatJid: 'a@b.example',
            preformatted: true,
          ),
        ],
        track: Track.standard,
        send: r.send,
      );
      expect(r.calls.single.wireBody, text);
    });

    test('the track asked for is the track used', () async {
      final r = _Recorder();
      await runForward(items: _items, track: Track.pq, send: r.send);
      expect(r.calls.every((c) => c.track == Track.pq), isTrue);
    });

    test('empty selection is a refusal', () async {
      final r = _Recorder();
      final outcome = await runForward(
        items: const [],
        track: Track.standard,
        send: r.send,
      );
      expect(outcome.ok, isFalse);
      expect(outcome.refused, ForwardRefusal.nothingSelected);
      expect(outcome.forwarded, 0);
      expect(r.calls, isEmpty);
    });

    test('stops at the first failure', () async {
      final r = _Recorder()..failAfter = 1;
      final outcome = await runForward(
        items: _items,
        track: Track.standard,
        send: r.send,
      );
      expect(outcome.ok, isFalse);
      expect(outcome.forwarded, 1);
      expect(r.calls.length, 2);
    });

    test('never falls back to another track', () async {
      final r = _Recorder()..failAfter = 0;
      final outcome = await runForward(
        items: _items,
        track: Track.pq,
        send: r.send,
      );
      expect(outcome.ok, isFalse);
      expect(r.calls.every((c) => c.track == Track.pq), isTrue);
    });
  });

  group('XEP-0297 (long-press)', () {
    test('empty selection is a refusal', () {
      expect(refuseStanzaForward(const []), ForwardRefusal.nothingSelected);
    });

    test('encrypted items are refused', () {
      expect(
        refuseStanzaForward(const [
          StanzaForwardItem(
            body: 'secret',
            originChatJid: 'a@b.example',
            author: 'alice',
            plaintext: false,
          ),
        ]),
        ForwardRefusal.notPlaintext,
      );
    });

    test('blank body is refused', () {
      expect(
        refuseStanzaForward(const [
          StanzaForwardItem(
            body: '   ',
            originChatJid: 'a@b.example',
            author: 'alice',
          ),
        ]),
        ForwardRefusal.notPlaintext,
      );
    });

    test('packs a forwarded child', () async {
      XMLNode? packed;
      final outcome = await runPlaintextForward(
        items: const [
          StanzaForwardItem(
            body: 'hello',
            originChatJid: 'alice@capulet.lit',
            author: 'alice@capulet.lit',
            fromFull: 'alice@capulet.lit/orchard',
            originId: 'orig-1',
          ),
        ],
        send:
            ({
              required original,
              required receivedAt,
              required outerBody,
            }) async {
              packed = packForwardedMessage(
                original: original,
                receivedAt: receivedAt,
              );
              expect(outerBody, isEmpty);
              return 'fwd-1';
            },
      );
      expect(outcome.ok, isTrue);
      expect(outcome.stanzaId, ['fwd-1']);
      expect(packed?.tag, 'forwarded');
      expect(
        packed?.firstTag('message')?.firstTag('body')?.innerText(),
        'hello',
      );
      expect(outcome.persisted.single.forwardBody, 'hello');
      expect(outcome.persisted.single.forwardFromJid, 'alice@capulet.lit');
    });

    test('stops when send returns null', () async {
      var calls = 0;
      final outcome = await runPlaintextForward(
        items: const [
          StanzaForwardItem(body: 'one', originChatJid: 'a@b', author: 'a@b'),
          StanzaForwardItem(body: 'two', originChatJid: 'a@b', author: 'a@b'),
        ],
        send:
            ({
              required original,
              required receivedAt,
              required outerBody,
            }) async {
              calls++;
              return calls == 1 ? 'ok' : null;
            },
      );
      expect(outcome.ok, isFalse);
      expect(outcome.forwarded, 1);
      expect(outcome.refused, ForwardRefusal.trackBlocked);
    });
  });

  group('forwardOriginJid', () {
    test('chat from → author bare', () {
      expect(
        forwardOriginJid(from: 'juliet@capulet.lit/balcony', type: 'chat'),
        'juliet@capulet.lit',
      );
    });

    test('groupchat from → room bare', () {
      expect(
        forwardOriginJid(
          from: 'coven@chat.shakespeare.lit/thirdwitch',
          type: 'groupchat',
        ),
        'coven@chat.shakespeare.lit',
      );
    });
  });

  group('inbound mapper forward fields', () {
    test('fills ForwardInfo for a direct plaintext forward', () {
      final event = MessageEvent(
        JID.fromString('bob@example.org/phone'),
        JID.fromString('me@example.org'),
        false,
        TypedMap<StanzaHandlerExtension>.fromList([
          MessageBodyData(''),
          UserForwardedData(
            body: 'Yet I should kill thee with much cherishing.',
            encrypted: false,
            from: 'juliet@capulet.lit/orchard',
            type: 'chat',
            id: '0202197',
            delay: DateTime.utc(2010, 7, 10, 23, 8, 25),
          ),
        ]),
        id: 'fwd-1',
        type: 'chat',
      );
      final inbound = inboundFromMessageEvent(event, roomStableIds: const {});
      expect(inbound, isNotNull);
      expect(inbound!.forward, isNotNull);
      expect(
        inbound.forward!.body,
        'Yet I should kill thee with much cherishing.',
      );
      expect(inbound.forward!.fromJid, 'juliet@capulet.lit');
      expect(inbound.forward!.author, 'juliet@capulet.lit');
      expect(inbound.forward!.originId, isEmpty);
    });

    test('keeps room stanza-id only for groupchat forwards', () {
      final event = MessageEvent(
        JID.fromString('bob@example.org/phone'),
        JID.fromString('me@example.org'),
        false,
        TypedMap<StanzaHandlerExtension>.fromList([
          UserForwardedData(
            body: 'hello room',
            encrypted: false,
            from: 'coven@chat.shakespeare.lit/thirdwitch',
            type: 'groupchat',
            id: 'room-stanza-42',
          ),
        ]),
        id: 'fwd-muc',
        type: 'chat',
      );
      final inbound = inboundFromMessageEvent(event, roomStableIds: const {});
      expect(inbound!.forward!.originId, 'room-stanza-42');
      expect(inbound.forward!.fromJid, 'coven@chat.shakespeare.lit');
    });

    test('ignores encrypted inner payloads', () {
      final event = MessageEvent(
        JID.fromString('bob@example.org/phone'),
        JID.fromString('me@example.org'),
        false,
        TypedMap<StanzaHandlerExtension>.fromList([
          const UserForwardedData(
            body: '',
            encrypted: true,
            from: 'a@b/c',
            type: 'chat',
          ),
        ]),
        id: 'fwd-enc',
        type: 'chat',
      );
      expect(
        ForwardInfo.fromUserForwarded(event.get<UserForwardedData>()),
        isNull,
      );
      expect(inboundFromMessageEvent(event, roomStableIds: const {}), isNull);
    });
  });
}
