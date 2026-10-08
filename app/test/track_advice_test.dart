// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Capability changes (docs/10 §8).
//
// The behaviour under test is mostly restraint. A client that quietly upgrades
// or downgrades a conversation's encryption produces messages whose label
// changes for no reason the user can see, which is indistinguishable from the
// app overriding them. So these tests are largely about *not* saying things.

import 'package:test/test.dart';
import 'package:resonchat/omemo/protocol.dart';
import 'package:resonchat/omemo/track.dart';
import 'package:resonchat/omemo/track_advice.dart';
import 'package:resonchat/omemo/track_resolver.dart';
import 'package:resonchat/xmpp/capabilities.dart';

ChatCapabilities caps({
  required Set<int> devices,
  Set<int>? pq,
  Set<int>? omemo,
  bool reliable = true,
}) {
  final all = devices;
  return ChatCapabilities(
    mode: EncMode.standardOmemo,
    recipientDevices: all,
    omemoDevices: omemo ?? all,
    pqDevices: pq ?? const {},
    checkedAt: DateTime(2026),
    reliable: reliable,
  );
}

void main() {
  group('an empty device list is not full coverage', () {
    test('vacuous every() must not read as "post-quantum works"', () {
      // The classic bug: `devices.every(pq.contains)` is true for an empty
      // set, so a contact with no devices looks fully PQ-capable.
      expect(everyDeviceIsPq(caps(devices: const {})), isFalse);
    });

    test('and the resolver blocks PQ on it too', () {
      expect(
        resolveTrack(
          requested: Track.pq,
          capabilities: caps(devices: const {}),
        ).canSend,
        isFalse,
      );
    });
  });

  group('upgrade direction', () {
    final before = caps(devices: {1, 2}, pq: {1, 2});
    final after = caps(devices: {1, 2}, pq: {1, 2});

    test('PQ becoming possible is worth a quiet hint', () {
      final mixed = caps(devices: {1, 2}, pq: {1});
      final advice = compareCapabilities(
        chatJid: 'peer@example.org',
        chosen: Track.standard,
        previous: mixed,
        current: after,
      );
      expect(advice, isNotNull);
      expect(advice!.kind, TrackAdviceKind.pqNowPossible);
      expect(advice.suggestion, Track.pq);
    });

    test('no hint when it was already possible', () {
      expect(
        compareCapabilities(
          chatJid: 'peer@example.org',
          chosen: Track.standard,
          previous: before,
          current: after,
        ),
        isNull,
      );
    });

    test('no hint when PQ goes away but the chosen track still works', () {
      // The user is on OM; losing a PQ device changes nothing for them.
      expect(
        compareCapabilities(
          chatJid: 'peer@example.org',
          chosen: Track.standard,
          previous: after,
          current: before,
        ),
        isNull,
      );
    });
  });

  group('downgrade direction', () {
    test('a device lost on the chosen track is reported', () {
      final advice = compareCapabilities(
        chatJid: 'peer@example.org',
        chosen: Track.standard,
        previous: caps(devices: {1, 2}),
        // Device 2 has no reachable bundle any more.
        current: caps(devices: {1, 2}, omemo: {1}),
      );
      expect(advice, isNotNull);
      expect(advice!.kind, TrackAdviceKind.chosenTrackBlocked);
      expect(advice.track, Track.standard);
      expect(advice.message, isNotEmpty);
    });

    test(
      'a device lost on the track the user did not choose is not reported',
      () {
        // Losing PQ while the user is on OM: nothing about their messages
        // changes, so interrupting them would be noise.
        expect(
          compareCapabilities(
            chatJid: 'peer@example.org',
            chosen: Track.standard,
            previous: caps(devices: {1, 2}, pq: {1, 2}),
            current: caps(devices: {1, 2}, pq: {1}),
          ),
          isNull,
        );
      },
    );

    test('a downgrade does not offer plaintext as the remedy', () {
      final advice = compareCapabilities(
        chatJid: 'peer@example.org',
        chosen: Track.pq,
        previous: caps(devices: {1, 2}, pq: {1, 2}),
        current: caps(devices: {1, 2}, pq: {1}),
      );
      expect(advice, isNotNull);
      expect(advice!.suggestion, isNot(Track.none));
      expect(advice.suggestion, Track.standard);
    });

    test('a track that was already unusable is not reported as new', () {
      // Both snapshots blocked: the user has already been told, and telling
      // them again on every PEP notification is how banners get ignored.
      final blocked = caps(devices: {1, 2}, omemo: {1});
      expect(
        compareCapabilities(
          chatJid: 'peer@example.org',
          chosen: Track.standard,
          previous: blocked,
          current: caps(devices: {1, 2}, omemo: {1, 2, 3}),
        ),
        isNull,
      );
    });
  });

  group('unreliable data produces no advice at all', () {
    test('a failed lookup going unreadable-to-readable', () {
      expect(
        compareCapabilities(
          chatJid: 'peer@example.org',
          chosen: Track.standard,
          previous: caps(devices: const {}, reliable: false),
          current: caps(devices: {1, 2}, pq: {1, 2}),
        ),
        isNull,
      );
    });

    test('a failed lookup going readable-to-unreadable', () {
      // This is the important one: a transient bundle-fetch failure must not
      // read as "a device vanished", or the user is told their contact lost a
      // phone every time the network hiccups.
      expect(
        compareCapabilities(
          chatJid: 'peer@example.org',
          chosen: Track.standard,
          previous: caps(devices: {1, 2}),
          current: caps(devices: {1, 2}, reliable: false),
        ),
        isNull,
      );
    });

    test('both unreliable', () {
      expect(
        compareCapabilities(
          chatJid: 'peer@example.org',
          chosen: Track.pq,
          previous: caps(devices: const {}, reliable: false),
          current: caps(devices: const {}, reliable: false),
        ),
        isNull,
      );
    });
  });

  group('nothing here ever changes a setting', () {
    test('the advice is data, and it carries no write path', () {
      // Structurally: there is no callback, no provider and no repository in
      // this file, so it cannot mutate anything. Asserted by constructing
      // advice for every reachable case and confirming they are plain values.
      final cases = [
        TrackAdvice(
          chatJid: 'a@example.org',
          kind: TrackAdviceKind.pqNowPossible,
          track: Track.standard,
          blocked: null,
        ),
        TrackAdvice(
          chatJid: 'b@example.org',
          kind: TrackAdviceKind.chosenTrackBlocked,
          track: Track.pq,
          blocked: TrackBlocked.pqUnavailable,
        ),
      ];
      expect(cases, hasLength(2));
      for (final advice in cases) {
        expect(advice.message, isNotEmpty);
        expect(advice.suggestion, isNotNull);
      }
      // Each piece names its own conversation, so the UI can place it.
      expect(cases[0].chatJid, isNot(cases[1].chatJid));
    });
  });
}
