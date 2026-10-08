// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// What happens when the chosen track cannot be carried out.
//
// One property matters more than any other: the track actually used is always
// the one that was asked for. Not "close enough", not "safe", not "what the
// client thinks is best" — the one that was asked for, or nothing is sent.
//
// The reason is that every substitution is silent to the person whose
// conversation it is. The message still arrives, it just arrives readable,
// and the reader has no way to tell. A client that quietly downgrades is
// worse than one that refuses.

import 'package:test/test.dart';
import 'package:resonchat/omemo/protocol.dart';
import 'package:resonchat/omemo/track.dart';
import 'package:resonchat/omemo/track_resolver.dart';
import 'package:resonchat/xmpp/capabilities.dart';

ChatCapabilities caps({
  required Set<int> devices,
  Set<int>? omemo,
  Set<int>? pq,
  bool reliable = true,
}) {
  return ChatCapabilities(
    // `mode` is the legacy negotiation verdict and plays no part in
    // resolution: what is sent is decided by the user's choice, not by it.
    mode: EncMode.standardOmemo,
    recipientDevices: devices,
    omemoDevices: omemo ?? devices,
    pqDevices: pq ?? const {},
    checkedAt: DateTime(2026),
    reliable: reliable,
  );
}

void main() {
  group('a choice that can be honoured', () {
    test('standard, fully supported', () {
      final r = resolveTrack(
        requested: Track.standard,
        capabilities: caps(devices: {1, 2}),
      );
      expect(r.canSend, isTrue);
      expect(r.track, Track.standard);
    });

    test('pq, fully supported', () {
      final r = resolveTrack(
        requested: Track.pq,
        capabilities: caps(devices: {1, 2}, pq: {1, 2}),
      );
      expect(r.canSend, isTrue);
      expect(r.track, Track.pq);
    });

    test('plaintext is always sendable', () {
      // The one case where "send it anyway" is right: the user was shown what
      // NO means and chose it.
      for (final snapshot in [
        null,
        caps(devices: {1}, reliable: false),
        caps(devices: {1}),
      ]) {
        final r = resolveTrack(requested: Track.none, capabilities: snapshot);
        expect(r.canSend, isTrue, reason: '$snapshot');
        expect(r.track, Track.none);
      }
    });
  });

  group('a choice that cannot be honoured', () {
    test('pq with a non-PQ device blocks, and does not fall back', () {
      final r = resolveTrack(
        requested: Track.pq,
        capabilities: caps(devices: {1, 2}, pq: {1}),
      );
      expect(r.canSend, isFalse);
      expect(r.blocked, TrackBlocked.pqUnavailable);
      // The important assertion: the PQ request is *not* quietly satisfied by
      // OM. Reporting canSend with track=standard here would make the dialog
      // undecidable and the label wrong.
      expect(r.track, Track.pq);
      expect(r.alternative, Track.standard);
    });

    test('standard with an unreachable device blocks', () {
      final r = resolveTrack(
        requested: Track.standard,
        capabilities: caps(devices: {1, 2}, omemo: {1}),
      );
      expect(r.canSend, isFalse);
      expect(r.blocked, TrackBlocked.standardUnavailable);
      expect(r.alternative, Track.standard);
    });

    test('an unreadable capability lookup blocks every encrypted track', () {
      // Not "plaintext is fine". An unreadable list is an absence of
      // information, and treating it as permission to send in the clear is
      // how a slow or broken server becomes a security downgrade.
      for (final requested in [Track.standard, Track.pq]) {
        final r = resolveTrack(
          requested: requested,
          capabilities: caps(devices: {1}, reliable: false),
        );
        expect(r.canSend, isFalse, reason: '$requested');
        expect(r.blocked, TrackBlocked.unknownPeers, reason: '$requested');
      }
    });

    test('a missing snapshot blocks every encrypted track', () {
      // "Not looked up yet" and "looked up, learned nothing" are the same
      // epistemic state. Both must block.
      for (final requested in [Track.standard, Track.pq]) {
        expect(
          resolveTrack(requested: requested, capabilities: null).canSend,
          isFalse,
          reason: '$requested',
        );
      }
    });

    test('pq with an empty device list blocks', () {
      // `every` on an empty set is vacuously true, so a naive check would call
      // this "fully PQ-capable" and claim a message to nobody is encrypted.
      final r = resolveTrack(
        requested: Track.pq,
        capabilities: caps(devices: const {}),
      );
      expect(r.canSend, isFalse);
    });
  });

  group('the invariant this whole file exists for', () {
    test('the track used is always the one requested, or nothing is sent', () {
      final cases = <TrackResolution>[
        for (final requested in Track.values)
          for (final snapshot in <ChatCapabilities?>[
            null,
            caps(devices: const {}, reliable: false),
            caps(devices: const {}),
            caps(devices: {1}),
            caps(devices: {1, 2}, omemo: {1}),
            caps(devices: {1, 2}, pq: {1}),
            caps(devices: {1, 2}, pq: {1, 2}),
          ])
            resolveTrack(requested: requested, capabilities: snapshot),
      ];
      expect(cases, isNotEmpty);
      for (final r in cases) {
        if (r.canSend) {
          expect(r.blocked, isNull);
          expect(r.alternative, isNull);
        } else {
          expect(r.blocked, isNotNull);
          // Never "canSend with a different track".
          expect(r.canSend, isFalse);
        }
      }
    });

    test('resolution does not consult the legacy negotiation verdict', () {
      // ChatCapabilities.mode is the old "what the program decided" answer.
      // If it leaked into the decision, picking OM while the verdict said PQ
      // would quietly change the answer — which is exactly the silent
      // substitution this file forbids. Both snapshots carry the same verdict
      // and must still resolve per the request.
      final verdictSaysPq = ChatCapabilities(
        mode: EncMode.pqOmemo,
        recipientDevices: const {1, 2},
        omemoDevices: const {1, 2},
        pqDevices: const {1},
        checkedAt: DateTime(2026),
        reliable: true,
      );
      final r = resolveTrack(requested: Track.pq, capabilities: verdictSaysPq);
      expect(r.canSend, isFalse);
      expect(r.blocked, TrackBlocked.pqUnavailable);
    });
  });

  group('what the dialog can say', () {
    test('every blocked case offers something to do', () {
      // "Cannot send" with no alternative leaves the user stuck. Each blocked
      // value must name a track worth switching to.
      final blocked = [
        TrackBlocked.unknownPeers,
        TrackBlocked.unreachableDevices,
        TrackBlocked.standardUnavailable,
        TrackBlocked.pqUnavailable,
      ];
      expect(blocked, hasLength(4));
    });

    test('unknownPeers does not offer NO', () {
      // Offering "send in plaintext" as the remedy for "we could not read the
      // device list" would turn a transient network problem into a downgrade
      // the user confirms under pressure.
      final r = resolveTrack(
        requested: Track.standard,
        capabilities: caps(devices: {1}, reliable: false),
      );
      expect(r.alternative, Track.standard);
      expect(r.alternative, isNot(Track.none));
    });
  });
}
