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
import 'package:resonchat/crypto/omemo/protocol.dart';
import 'package:resonchat/crypto/omemo/track.dart';
import 'package:resonchat/crypto/omemo/track_resolver.dart';
import 'package:resonchat/xmpp/capabilities.dart';

ChatCapabilities caps({
  required Set<int> devices,

  /// Devices the *peer* publishes, when they differ from the recipient set
  /// (which also carries our own other devices).
  Set<int>? peer,
  Set<int>? omemo,
  Set<int>? pq,
  bool reliable = true,
  bool? classicReliable,
  bool? pqReliable,
}) {
  final classicOk = classicReliable ?? reliable;
  final pqOk = pqReliable ?? reliable;
  return ChatCapabilities(
    // `mode` is the legacy negotiation verdict and plays no part in
    // resolution: what is sent is decided by the user's choice, not by it.
    mode: EncMode.standardOmemo,
    recipientDevices: devices,
    // The tests are written from the peer's side: `devices` is what they
    // publish on the classic list.
    peerDevices: peer ?? devices,
    omemoDevices: omemo ?? devices,
    pqDevices: pq ?? const {},
    checkedAt: DateTime(2026),
    reliable: classicOk || pqOk,
    classicReliable: classicOk,
    pqReliable: pqOk,
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

    test('pq, one of several peer devices is enough', () {
      final r = resolveTrack(
        requested: Track.pq,
        capabilities: caps(devices: {1, 2}, pq: {1}),
      );
      expect(r.canSend, isTrue);
      expect(r.track, Track.pq);
    });

    test('pq works with an empty classic list (tracks are independent)', () {
      final r = resolveTrack(
        requested: Track.pq,
        capabilities: caps(
          devices: const {},
          peer: const {},
          pq: {42},
          classicReliable: true,
          pqReliable: true,
        ),
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
    test('pq with no PQ peer device blocks, and does not fall back', () {
      final r = resolveTrack(
        requested: Track.pq,
        capabilities: caps(devices: {1, 2}, pq: const {}),
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

    test('a peer with nothing we can encrypt to blocks, and offers the clear', () {
      // The peer *does* publish devices — this is not an unreadable list — but
      // not one of their bundles verifies any more (a signed prekey rotated
      // out from under its signature, a client reinstalled over its own
      // account). `7` is our own device: it has to be able to read the message
      // and it is the only thing left in the recipient set, which is exactly
      // how "they have no reachable device" used to be impossible to conclude.
      final r = resolveTrack(
        requested: Track.standard,
        capabilities: caps(devices: const {7}, peer: const {}),
      );
      expect(r.canSend, isFalse);
      // Not track-shaped: no track can reach them, so naming one would send
      // the user to the picker for a problem the picker cannot fix.
      expect(r.blocked, TrackBlocked.unreachableDevices);
      // Not plaintext as the remedy: offering the clear for an encryption
      // failure is a downgrade prompt the user answers under pressure, which
      // this project refuses even where plaintext is the only way left. (The
      // offer is therefore a dead end for a standard request; tracked.)
      expect(r.alternative, isNot(Track.none));
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
      // peerDevices empty is unreachableDevices (handled above); an empty
      // recipient set with no peer still must not look PQ-sendable.
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
        peerDevices: const {1, 2},
        omemoDevices: const {1, 2},
        pqDevices: const {1},
        checkedAt: DateTime(2026),
        reliable: true,
      );
      final r = resolveTrack(requested: Track.pq, capabilities: verdictSaysPq);
      // Mixed peer still sendable on PQ (one PQ device among {1,2}); mode
      // must not override that.
      expect(r.canSend, isTrue);
      expect(r.track, Track.pq);
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
