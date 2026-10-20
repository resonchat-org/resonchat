// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Forwarding.
//
// The decision these tests protect is the one that looks like a limitation: a
// forward is a *new, re-encrypted* message, not the original stanza wrapped in
// XEP-0297's `<forwarded/>`.
//
// Reusing the stanza would carry encryption meant for the original recipient.
// The new recipient would get a blob they cannot open, and the wrapper's
// metadata would still name the original recipient. So the original ciphertext
// is deliberately not re-sent, and these tests say so rather than leaving it to
// be rediscovered as a missing feature.

import 'package:test/test.dart';

import 'package:resonchat/crypto/dual/track.dart';
import 'package:resonchat/crypto/dual/track_resolver.dart';
import 'package:resonchat/xmpp/connection.dart';
import 'package:resonchat/xmpp/forwarding.dart';

/// A sender that records what it was asked to send.
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
  group('what is on the wire', () {
    test('each message quotes the original text', () async {
      // Without this the recipient gets "Forwarded from a@b" and nothing else,
      // which is not a forward.
      final r = _Recorder();
      await runForward(items: _items, track: Track.standard, send: r.send);
      expect(r.calls.first.wireBody, contains('> the first thing'));
      expect(
        r.calls.first.wireBody,
        contains(forwardAttribution('a@b.example')),
      );
    });

    test('the attribution is not mixed into the quoted lines', () {
      // A reader seeing `> Forwarded from a@b` above `> the real text` cannot
      // tell which line was said and which was the label.
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
      // No substitution: a forward that silently became plaintext is a message
      // the user did not agree to send that way.
      final r = _Recorder();
      await runForward(items: _items, track: Track.pq, send: r.send);
      expect(r.calls.every((c) => c.track == Track.pq), isTrue);
    });
  });

  group('nothing selected', () {
    test('is a refusal, not a silent success', () async {
      // An empty forward reporting success leaves the user believing a message
      // was passed on when nothing was.
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
  });

  group('a refused track', () {
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

    test('and says how many went out before it stopped', () async {
      final r = _Recorder()..failAfter = 0;
      final outcome = await runForward(
        items: _items,
        track: Track.standard,
        send: r.send,
      );
      expect(outcome.forwarded, 0);
      expect(outcome.refused, ForwardRefusal.trackBlocked);
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
}
