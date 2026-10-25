// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// P0 send-path policy tests (docs/11): session-aware bundle needs, group A
// exclusion, fail-closed blocking, stale-generation races and stable identity
// fingerprints across prekey rotation.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:moxxmpp/moxxmpp.dart';
import 'package:omemo_dart/omemo_dart_omemo2.dart';

import 'package:resonchat/crypto/dual/dual_track_manager.dart';
import 'package:resonchat/crypto/dual/fingerprint_trust.dart';
import 'package:resonchat/crypto/dual/pq_device_list_snapshot.dart';
import 'package:resonchat/crypto/omemo2/pq_peer_resolver.dart';
import 'package:resonchat/crypto/omemo2/pq_session.dart';

class _FakeTracks implements DualTrackManager {
  _FakeTracks({Map<String, Map<int, PqDevice>>? bundles})
    : bundles = bundles ?? {};

  final Map<String, Map<int, PqDevice>> bundles;
  Completer<void>? gate;
  void Function()? onFetch;
  int bundleFetches = 0;

  @override
  Future<List<PqDevice>> loadPqDevicesByIds(JID jid, Iterable<int> ids) async {
    bundleFetches++;
    onFetch?.call();
    final wait = gate;
    if (wait != null) await wait.future;
    final byId = bundles[jid.toBare().toString()] ?? const <int, PqDevice>{};
    return [
      for (final id in ids)
        if (byId[id] != null) byId[id]!,
    ];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName} is not used here');
}

class _FakeSessions implements PqSessionManager {
  bool defaultSession = false;
  final Map<String, Set<int>> sessions = {};
  int forgetCalls = 0;

  @override
  Future<bool> hasSession(String jid, int deviceId) async =>
      sessions[jid]?.contains(deviceId) ?? defaultSession;

  @override
  Future<void> forgetSession(String jid, int deviceId) async {
    forgetCalls++;
    sessions[jid]?.remove(deviceId);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName} is not used here');
}

class _FakeTrust implements FingerprintTrustStore {
  final Map<String, String> fingerprints = {};
  final Map<String, FingerprintTrust> trustByJid = {};
  int rememberCalls = 0;

  String _key(String jid, int deviceId) => '$jid/$deviceId';

  @override
  Future<void> syncAnnouncedDevices({
    required String jid,
    required Iterable<int> announcedIds,
    required bool omemo2,
  }) async {}

  @override
  Future<String?> fingerprintOfDevice(
    String jid,
    int deviceId, {
    required bool omemo2,
  }) async => fingerprints[_key(jid, deviceId)];

  @override
  Future<void> rememberDevice({
    required String jid,
    required int deviceId,
    required String fingerprint,
    required bool omemo2,
  }) async {
    rememberCalls++;
    fingerprints[_key(jid, deviceId)] = fingerprint;
  }

  @override
  Future<FingerprintTrust> getTrust(String jid, String fingerprint) async =>
      trustByJid[jid] ?? FingerprintTrust.blind;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName} is not used here');
}

PqSnapshotProvider _snapshots(Map<String, Set<int>> lists) {
  return (jid) async {
    final now = DateTime.now();
    return PqDeviceListSnapshot(
      devices: lists[jid.toBare().toString()] ?? const <int>{},
      fetchedAt: now,
      expiresAt: now.add(const Duration(minutes: 5)),
      reliable: true,
      generation: 0,
    );
  };
}

Future<Omemo2Device> _device({
  required String jid,
  required int id,
  Omemo2Device? identityFrom,
  Omemo2Device? prekeysFrom,
  required int pqSeed,
}) async {
  final base = await Omemo2Device.generate(
    jid,
    opkCount: 1,
    pqOpkCount: 1,
    deviceId: id,
  );
  final identity = identityFrom ?? base;
  final prekeys = prekeysFrom ?? base;
  return Omemo2Device(
    jid: jid,
    id: id,
    ikEd: identity.ikEd,
    ikDh: identity.ikDh,
    spk: prekeys.spk,
    spkId: prekeys.spkId,
    spkSignature: prekeys.spkSignature,
    pqSpk: prekeys.pqSpk,
    pqSpkSecret: prekeys.pqSpkSecret,
    pqSpkId: prekeys.pqSpkId,
    pqSpkSignature: prekeys.pqSpkSignature,
    opks: prekeys.opks,
    pqOpks: prekeys.pqOpks,
    peerPqIdentityKey: Uint8List.fromList(List.filled(32, pqSeed)),
  );
}

void main() {
  const peer = 'bob@example.org';
  const deviceId = 7;

  test(
    'session reuse skips bundle fetch and new-session registration',
    () async {
      final device = await _device(jid: peer, id: deviceId, pqSeed: 1);
      final tracks = _FakeTracks(
        bundles: {
          peer: {deviceId: device},
        },
      );
      final sessions = _FakeSessions();
      final trust = _FakeTrust();
      final resolver = PqPeerResolver(
        tracks: () => tracks,
        sessions: sessions,
        snapshotFor: _snapshots({
          peer: {deviceId},
        }),
        fingerprintTrust: trust,
      );

      final first = await resolver.resolve(requestedJids: [peer]);
      expect(first.blocked, isFalse);
      expect(first.newDevices, hasLength(1));
      expect(tracks.bundleFetches, 1);

      sessions.sessions[peer] = {deviceId};
      final second = await resolver.resolve(requestedJids: [peer]);
      expect(second.blocked, isFalse);
      expect(second.newDevices, isEmpty);
      expect(second.allowedDeviceIds[peer], {deviceId});
      expect(
        tracks.bundleFetches,
        1,
        reason:
            'an established session with a fresh fingerprint needs no bundle',
      );
    },
  );

  test('group A excludes an untrusted member and keeps the others', () async {
    const peer2 = 'carol@example.org';
    final d1 = await _device(jid: peer, id: 1, pqSeed: 1);
    final d2 = await _device(jid: peer2, id: 2, pqSeed: 2);
    final tracks = _FakeTracks(
      bundles: {
        peer: {1: d1},
        peer2: {2: d2},
      },
    );
    final sessions = _FakeSessions()..defaultSession = true;
    final trust = _FakeTrust()..trustByJid[peer] = FingerprintTrust.untrusted;
    final resolver = PqPeerResolver(
      tracks: () => tracks,
      sessions: sessions,
      snapshotFor: _snapshots({
        peer: {1},
        peer2: {2},
      }),
      fingerprintTrust: trust,
    );

    final result = await resolver.resolve(requestedJids: [peer, peer2]);
    expect(result.blocked, isFalse);
    expect(result.allowedDeviceIds[peer], isEmpty);
    expect(result.allowedDeviceIds[peer2], {2});
    expect(result.excluded[peer], {1: PqDeviceExclusion.untrusted});
    expect(result.actualJids, [peer2]);
  });

  test('an undecided device blocks the whole send', () async {
    final device = await _device(jid: peer, id: deviceId, pqSeed: 1);
    final tracks = _FakeTracks(
      bundles: {
        peer: {deviceId: device},
      },
    );
    final sessions = _FakeSessions()..defaultSession = true;
    final trust = _FakeTrust()..trustByJid[peer] = FingerprintTrust.undecided;
    final resolver = PqPeerResolver(
      tracks: () => tracks,
      sessions: sessions,
      snapshotFor: _snapshots({
        peer: {deviceId},
      }),
      fingerprintTrust: trust,
    );

    final result = await resolver.resolve(requestedJids: [peer]);
    expect(result.blocked, isTrue);
    expect(result.blockedReason, PqBlockReason.undecidedDevice);
  });

  test('a missing bundle for a sessionless device blocks the send', () async {
    final tracks = _FakeTracks(bundles: {peer: {}});
    final resolver = PqPeerResolver(
      tracks: () => tracks,
      sessions: _FakeSessions(),
      snapshotFor: _snapshots({
        peer: {deviceId},
      }),
      fingerprintTrust: _FakeTrust(),
    );

    final result = await resolver.resolve(requestedJids: [peer]);
    expect(result.blocked, isTrue);
    expect(result.blockedReason, PqBlockReason.missingSessionMaterial);
  });

  test('a failed bundle refresh keeps a trusted established session', () async {
    final device = await _device(jid: peer, id: deviceId, pqSeed: 1);
    final tracks = _FakeTracks(
      bundles: {
        peer: {deviceId: device},
      },
    );
    final sessions = _FakeSessions();
    final trust = _FakeTrust();
    final resolver = PqPeerResolver(
      tracks: () => tracks,
      sessions: sessions,
      snapshotFor: _snapshots({
        peer: {deviceId},
      }),
      fingerprintTrust: trust,
    );

    await resolver.resolve(requestedJids: [peer]);
    sessions.sessions[peer] = {deviceId};
    tracks.bundles[peer] = {};
    resolver.invalidate(JID.fromString(peer));

    final second = await resolver.resolve(requestedJids: [peer]);
    expect(second.blocked, isFalse);
    expect(second.allowedDeviceIds[peer], {deviceId});
    expect(second.newDevices, isEmpty);
    expect(
      trust.rememberCalls,
      1,
      reason: 'the fallback must not write a fingerprint cache entry',
    );
  });

  test(
    'an empty announced list blocks instead of meaning no recipients',
    () async {
      final resolver = PqPeerResolver(
        tracks: () => _FakeTracks(),
        sessions: _FakeSessions(),
        snapshotFor: _snapshots({peer: const <int>{}}),
        fingerprintTrust: _FakeTrust(),
      );

      final result = await resolver.resolve(requestedJids: [peer]);
      expect(result.blocked, isTrue);
      expect(result.blockedReason, PqBlockReason.noAnnouncedDevices);
    },
  );

  test(
    'prekey rotation does not change the stable fingerprint or session',
    () async {
      final firstDevice = await _device(jid: peer, id: deviceId, pqSeed: 1);
      final rotatedPrekeys = await _device(jid: peer, id: deviceId, pqSeed: 1);
      final rotated = await _device(
        jid: peer,
        id: deviceId,
        identityFrom: firstDevice,
        prekeysFrom: rotatedPrekeys,
        pqSeed: 1,
      );
      final tracks = _FakeTracks(
        bundles: {
          peer: {deviceId: firstDevice},
        },
      );
      final sessions = _FakeSessions();
      final trust = _FakeTrust();
      final resolver = PqPeerResolver(
        tracks: () => tracks,
        sessions: sessions,
        snapshotFor: _snapshots({
          peer: {deviceId},
        }),
        fingerprintTrust: trust,
      );

      await resolver.resolve(requestedJids: [peer]);
      sessions.sessions[peer] = {deviceId};
      resolver.invalidate(JID.fromString(peer));
      tracks.bundles[peer]![deviceId] = rotated;

      final second = await resolver.resolve(requestedJids: [peer]);
      expect(second.blocked, isFalse);
      expect(second.newDevices, isEmpty);
      expect(
        sessions.forgetCalls,
        0,
        reason: 'rotating SPK/OPK/KEM keys is not an identity change',
      );
      expect(trust.rememberCalls, 1);
    },
  );

  test('a changed identity key drops the session and re-handshakes', () async {
    final firstDevice = await _device(jid: peer, id: deviceId, pqSeed: 1);
    final changedIdentity = await _device(jid: peer, id: deviceId, pqSeed: 2);
    final changed = await _device(
      jid: peer,
      id: deviceId,
      identityFrom: changedIdentity,
      prekeysFrom: changedIdentity,
      pqSeed: 2,
    );
    final tracks = _FakeTracks(
      bundles: {
        peer: {deviceId: firstDevice},
      },
    );
    final sessions = _FakeSessions();
    final trust = _FakeTrust();
    final resolver = PqPeerResolver(
      tracks: () => tracks,
      sessions: sessions,
      snapshotFor: _snapshots({
        peer: {deviceId},
      }),
      fingerprintTrust: trust,
    );

    await resolver.resolve(requestedJids: [peer]);
    sessions.sessions[peer] = {deviceId};
    resolver.invalidate(JID.fromString(peer));
    tracks.bundles[peer]![deviceId] = changed;

    final second = await resolver.resolve(requestedJids: [peer]);
    expect(second.blocked, isFalse);
    expect(sessions.forgetCalls, 1);
    expect(second.newDevices, hasLength(1));
    expect(second.newDevices.single.id, deviceId);
  });

  test('PEP invalidation during a bundle fetch fails closed', () async {
    final device = await _device(jid: peer, id: deviceId, pqSeed: 1);
    final started = Completer<void>();
    final gate = Completer<void>();
    final tracks =
        _FakeTracks(
            bundles: {
              peer: {deviceId: device},
            },
          )
          ..gate = gate
          ..onFetch = (() => started.complete());
    final resolver = PqPeerResolver(
      tracks: () => tracks,
      sessions: _FakeSessions(),
      snapshotFor: _snapshots({
        peer: {deviceId},
      }),
      fingerprintTrust: _FakeTrust(),
    );

    final pending = resolver.resolve(requestedJids: [peer]);
    await started.future;
    resolver.invalidate(JID.fromString(peer));
    gate.complete();

    final result = await pending;
    expect(result.blocked, isTrue);
    expect(result.blockedReason, PqBlockReason.staleResolution);
  });
}
