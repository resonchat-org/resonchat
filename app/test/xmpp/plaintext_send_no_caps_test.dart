// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// A plaintext send must not wait for a capability lookup.
//
// The bug this locks: choosing "NO" while the connection was down inserted a
// `waiting` row, then the send path still asked for the peer's PEP device
// lists. That lookup could outlive the connection, so the bubble stayed on the
// clock forever and no stanza was ever written.

import 'package:flutter_test/flutter_test.dart';
import 'package:moxxmpp/moxxmpp.dart';

import 'package:resonchat/crypto/dual/dual_track_manager.dart';
import 'package:resonchat/crypto/dual/track.dart';
import 'package:resonchat/xmpp/connection.dart';
import 'package:resonchat/xmpp/encryption/capabilities.dart';

class _FakeTracks implements DualTrackManager {
  @override
  Future<({Set<int> devices, bool listReadable})> resolveOmemoDevices(
    JID jid,
  ) async => (devices: const {1}, listReadable: true);

  @override
  Future<({Set<int> devices, bool listReadable})> fetchPqDeviceIds(
    JID jid,
  ) async => (devices: const {1}, listReadable: true);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName} is not used here');
}

void main() {
  test('Track.none never consults the capability service', () async {
    var lookups = 0;
    final xmpp = XmppService()
      ..attachCapabilities(
        CapabilityService(
          tracks: () {
            lookups++;
            return _FakeTracks();
          },
          ourDeviceId: () async => 100,
          ourPqDevices: () async => const {100},
        ),
      );

    // No connection: the send must fail immediately, but only after the
    // plaintext path, not after a PEP round-trip.
    await expectLater(
      xmpp.sendOnTrack(
        JID.fromString('bob@example.org'),
        'hello in the clear',
        track: Track.none,
      ),
      throwsA(isA<StateError>()),
    );
    expect(lookups, 0, reason: 'plaintext has no device list to resolve');
  });
}
