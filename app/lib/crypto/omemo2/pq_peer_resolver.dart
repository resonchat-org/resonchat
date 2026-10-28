// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Session-aware PQ recipient resolution (docs/11).
//
// The resolver owns the *decision*, not the device-list cache. The announced
// list always comes from CapabilityService.pqSnapshotFor; bundles are fetched
// only for devices that need a session or have no fresh stable fingerprint.
//
// Policy:
//   * explicitly untrusted devices are excluded and the rest may continue;
//   * undecided devices, unverifiable identities, unreadable device lists and
//     missing session material block the whole send;
//   * a fingerprint is derived only from stable identity keys, never from
//     rotating SPK / OPK / KEM prekeys.

import 'dart:typed_data';

import 'package:hex/hex.dart';
import 'package:logging/logging.dart';
import 'package:moxxmpp/moxxmpp.dart';

import 'package:resonchat/crypto/dual/bounded.dart';
import 'package:resonchat/crypto/dual/dual_track_manager.dart';
import 'package:resonchat/crypto/dual/fingerprint_trust.dart';
import 'package:resonchat/crypto/dual/pq_device_list_snapshot.dart';
import 'package:resonchat/crypto/omemo2/pq_auth.dart';
import 'package:resonchat/crypto/omemo2/pq_session.dart';
import 'package:resonchat/persistence/omemo2_pq_pin_store.dart';

/// Why a PQ send cannot proceed. These all fail closed for the whole send.
enum PqBlockReason {
  invalidTarget,
  deviceListUnreadable,
  staleResolution,
  noAnnouncedDevices,
  missingSessionMaterial,
  undecidedDevice,
  unverifiableIdentity,

  /// Pinned `<pq-ik>` differs from the bundle / handshake (identity change).
  pqIdentityChanged,
  trustStoreError,
}

/// Non-blocking exclusion reasons. Only explicit distrust may use one.
enum PqDeviceExclusion { untrusted }

typedef PqSnapshotProvider = Future<PqDeviceListSnapshot> Function(JID jid);

class PqPeerResolution {
  const PqPeerResolution({
    required this.requestedJids,
    required this.announcedDeviceIds,
    required this.allowedDeviceIds,
    required this.newDevices,
    required this.excluded,
    this.blockedReason,
    this.blockedJid,
    this.blockedDeviceId,
  });

  final List<String> requestedJids;
  final Map<String, Set<int>> announcedDeviceIds;
  final Map<String, Set<int>> allowedDeviceIds;

  /// Bundles that must be registered before the strict encrypt call. Only
  /// devices that do not already have a session are included.
  final List<PqDevice> newDevices;

  final Map<String, Map<int, PqDeviceExclusion>> excluded;

  final PqBlockReason? blockedReason;
  final String? blockedJid;
  final int? blockedDeviceId;

  bool get blocked => blockedReason != null;

  /// JIDs with at least one allowed device. This is what goes to the vendor.
  List<String> get actualJids => [
    for (final jid in requestedJids)
      if ((allowedDeviceIds[jid] ?? const <int>{}).isNotEmpty) jid,
  ];
}

class _CachedFingerprint {
  const _CachedFingerprint({
    required this.fingerprint,
    required this.expiresAt,
    required this.generation,
  });

  final String fingerprint;
  final DateTime expiresAt;
  final int generation;

  bool isFresh(int currentGeneration) =>
      generation == currentGeneration && DateTime.now().isBefore(expiresAt);
}

class _DeviceWork {
  _DeviceWork({
    required this.jid,
    required this.deviceId,
    required this.hasSession,
    required this.generation,
    required this.needsBundle,
    this.cachedFingerprint,
  });

  final String jid;
  final int deviceId;
  bool hasSession;
  final int generation;
  final bool needsBundle;
  String? cachedFingerprint;
  PqDevice? device;
  String? fingerprint;
  bool bundleFailed = false;
}

class PqPeerResolver {
  PqPeerResolver({
    required this.tracks,
    required this.sessions,
    required this.snapshotFor,
    this.fingerprintTrust,
    this.pqPins,
    this.fingerprintTtl = const Duration(minutes: 30),
  });

  final Logger _log = Logger('PqPeerResolver');

  final DualTrackManager Function() tracks;
  final PqSessionManager sessions;
  final PqSnapshotProvider snapshotFor;
  final FingerprintTrustStore? fingerprintTrust;

  /// When set, refuse devices whose `<pq-ik>` conflicts with a pin.
  final Omemo2PqPinStore? pqPins;

  final Duration fingerprintTtl;

  final _fingerprints = <String, _CachedFingerprint>{};
  final _announced = <String, Set<int>>{};
  final _generation = <String, int>{};
  int _globalGeneration = 0;

  int _generationOf(String jid) => _generation[jid] ?? 0;

  /// PEP or local identity change: drop cached fingerprints and announced
  /// views for [jid]. In-flight resolutions detect the generation change and
  /// fail closed instead of installing stale answers.
  void invalidate(JID jid) {
    final bare = jid.toBare().toString();
    _generation[bare] = _generationOf(bare) + 1;
    _announced.remove(bare);
    _fingerprints.removeWhere((key, _) => key.startsWith('$bare\x00'));
  }

  void invalidateAll() {
    _announced.clear();
    _fingerprints.clear();
    _generation.clear();
    _globalGeneration++;
    // A resolve that captured a previous peer generation must not install
    // after this. Callers also invalidate CapabilityService, so the next
    // lookup re-reads.
  }

  Future<PqPeerResolution> resolve({
    required Iterable<String> requestedJids,
  }) async {
    final requested = <String>[];
    final seen = <String>{};
    try {
      for (final raw in requestedJids) {
        final bare = JID.fromString(raw).toBare().toString();
        if (seen.add(bare)) requested.add(bare);
      }
    } catch (e) {
      return _blocked(PqBlockReason.invalidTarget, requestedJids: requested);
    }
    if (requested.isEmpty) {
      return _blocked(PqBlockReason.invalidTarget, requestedJids: requested);
    }

    final globalGeneration = _globalGeneration;
    final announced = <String, Set<int>>{};
    final allowed = <String, Set<int>>{};
    final excluded = <String, Map<int, PqDeviceExclusion>>{};
    final newDevices = <PqDevice>[];
    final work = <_DeviceWork>[];

    for (final jid in requested) {
      final generation = _generationOf(jid);
      PqDeviceListSnapshot snapshot;
      try {
        snapshot = await snapshotFor(JID.fromString(jid));
      } catch (e) {
        _log.warning('PQ snapshot for $jid failed: $e');
        return _blocked(
          PqBlockReason.deviceListUnreadable,
          requestedJids: requested,
          jid: jid,
        );
      }
      if (globalGeneration != _globalGeneration ||
          generation != _generationOf(jid)) {
        return _blocked(
          PqBlockReason.staleResolution,
          requestedJids: requested,
          jid: jid,
        );
      }
      if (!snapshot.reliable) {
        return _blocked(
          PqBlockReason.deviceListUnreadable,
          requestedJids: requested,
          jid: jid,
        );
      }

      final ids = Set<int>.from(snapshot.devices);
      announced[jid] = ids;
      allowed[jid] = <int>{};
      if (ids.isEmpty) {
        return _blocked(
          PqBlockReason.noAnnouncedDevices,
          requestedJids: requested,
          jid: jid,
        );
      }

      final trust = fingerprintTrust;
      if (trust != null && !_sameIds(_announced[jid], ids)) {
        try {
          await trust.syncAnnouncedDevices(
            jid: jid,
            announcedIds: ids,
            omemo2: true,
          );
          if (generation == _generationOf(jid)) _announced[jid] = ids;
        } catch (e) {
          _log.warning('trust sync for $jid failed: $e');
          return _blocked(
            PqBlockReason.trustStoreError,
            requestedJids: requested,
            jid: jid,
          );
        }
      }

      for (final id in ids) {
        final hasSession = await sessions.hasSession(jid, id);
        final key = _fingerprintKey(jid, id);
        final cached = _fingerprints[key];
        if (cached != null && !cached.isFresh(generation)) {
          _fingerprints.remove(key);
        }
        final fresh = freshFingerprint(jid, id, generation);
        final needsBundle = !hasSession || (trust != null && fresh == null);
        work.add(
          _DeviceWork(
            jid: jid,
            deviceId: id,
            hasSession: hasSession,
            generation: generation,
            needsBundle: needsBundle,
            cachedFingerprint: needsBundle ? null : fresh,
          ),
        );
      }
    }

    // Bundle fetches are bounded across *all* peers, not per peer: three
    // round-trips total is the socket-safe cap (docs/11 §5.2).
    final needBundle = [
      for (final w in work)
        if (w.needsBundle) w,
    ];
    await forEachBounded(needBundle, kBundleFetchConcurrency, (w) async {
      try {
        final devices = await tracks().loadPqDevicesByIds(
          JID.fromString(w.jid),
          [w.deviceId],
        );
        if (devices.isEmpty) {
          w.bundleFailed = true;
        } else {
          w.device = devices.first;
        }
      } catch (e) {
        _log.warning('PQ bundle for ${w.jid}/${w.deviceId} failed: $e');
        w.bundleFailed = true;
      }
    });

    for (final w in work) {
      if (globalGeneration != _globalGeneration) {
        return _blocked(
          PqBlockReason.staleResolution,
          requestedJids: requested,
          jid: w.jid,
          deviceId: w.deviceId,
        );
      }
      if (w.bundleFailed) {
        final trust = fingerprintTrust;
        if (trust == null) {
          return _blocked(
            PqBlockReason.missingSessionMaterial,
            requestedJids: requested,
            jid: w.jid,
            deviceId: w.deviceId,
          );
        }
        try {
          final stored = await trust.fingerprintOfDevice(
            w.jid,
            w.deviceId,
            omemo2: true,
          );
          if (stored == null) {
            return _blocked(
              PqBlockReason.missingSessionMaterial,
              requestedJids: requested,
              jid: w.jid,
              deviceId: w.deviceId,
            );
          }
          final level = await trust.getTrust(w.jid, stored);
          switch (level) {
            case FingerprintTrust.untrusted:
              (excluded[w.jid] ??= {})[w.deviceId] =
                  PqDeviceExclusion.untrusted;
              continue;
            case FingerprintTrust.undecided:
              return _blocked(
                PqBlockReason.undecidedDevice,
                requestedJids: requested,
                jid: w.jid,
                deviceId: w.deviceId,
              );
            case FingerprintTrust.blind:
            case FingerprintTrust.verified:
              break;
          }
          if (!w.hasSession) {
            return _blocked(
              PqBlockReason.missingSessionMaterial,
              requestedJids: requested,
              jid: w.jid,
              deviceId: w.deviceId,
            );
          }
          // The bundle refresh failed, but an established session plus a
          // trusted stored identity is the documented safe fallback. Do not
          // write the fingerprint cache; the next send retries the bundle.
          allowed[w.jid]!.add(w.deviceId);
          continue;
        } catch (e) {
          _log.warning('trust fallback for ${w.jid}/${w.deviceId} failed: $e');
          return _blocked(
            PqBlockReason.trustStoreError,
            requestedJids: requested,
            jid: w.jid,
            deviceId: w.deviceId,
          );
        }
      }
      if (w.generation != _generationOf(w.jid)) {
        return _blocked(
          PqBlockReason.staleResolution,
          requestedJids: requested,
          jid: w.jid,
          deviceId: w.deviceId,
        );
      }

      final trust = fingerprintTrust;
      String? fingerprint = w.cachedFingerprint;

      if (w.device != null) {
        fingerprint = await _stableFingerprint(w.device!);
        if (fingerprint == null) {
          return _blocked(
            PqBlockReason.unverifiableIdentity,
            requestedJids: requested,
            jid: w.jid,
            deviceId: w.deviceId,
          );
        }

        try {
          final pinBlock = await _enforcePqPin(w.device!);
          if (pinBlock != null) {
            return _blocked(
              pinBlock,
              requestedJids: requested,
              jid: w.jid,
              deviceId: w.deviceId,
            );
          }
        } catch (e) {
          _log.warning('pq pin for ${w.jid}/${w.deviceId} failed: $e');
          return _blocked(
            PqBlockReason.trustStoreError,
            requestedJids: requested,
            jid: w.jid,
            deviceId: w.deviceId,
          );
        }

        if (trust != null) {
          try {
            final stored = await trust.fingerprintOfDevice(
              w.jid,
              w.deviceId,
              omemo2: true,
            );
            if (stored != null && stored != fingerprint) {
              // Legacy rows stored the 128-char hybrid as the trust key; migrate
              // in place without dropping the session. A real classical IK
              // change is a new device — drop the old session.
              final migratingHybrid =
                  stored.length == 128 && fingerprint.length == 66;
              if (!migratingHybrid) {
                _log.warning(
                  'PQ classical fingerprint changed for ${w.jid}/${w.deviceId}; '
                  'dropping the old session',
                );
                await sessions.forgetSession(w.jid, w.deviceId);
                w.hasSession = false;
              }
            }
            if (stored != fingerprint) {
              await trust.rememberDevice(
                jid: w.jid,
                deviceId: w.deviceId,
                fingerprint: fingerprint,
                omemo2: true,
              );
            }
          } catch (e) {
            _log.warning('trust lookup for ${w.jid}/${w.deviceId} failed: $e');
            return _blocked(
              PqBlockReason.trustStoreError,
              requestedJids: requested,
              jid: w.jid,
              deviceId: w.deviceId,
            );
          }
        }

        if (w.generation == _generationOf(w.jid)) {
          _fingerprints[_fingerprintKey(
            w.jid,
            w.deviceId,
          )] = _CachedFingerprint(
            fingerprint: fingerprint,
            expiresAt: DateTime.now().add(fingerprintTtl),
            generation: w.generation,
          );
        }
      } else if (trust != null && fingerprint != null) {
        // Fast path: session exists and the stable fingerprint is fresh.
        // If the row was removed, reseed it from the cached fingerprint.
        try {
          final stored = await trust.fingerprintOfDevice(
            w.jid,
            w.deviceId,
            omemo2: true,
          );
          if (stored == null) {
            await trust.rememberDevice(
              jid: w.jid,
              deviceId: w.deviceId,
              fingerprint: fingerprint,
              omemo2: true,
            );
          } else if (stored != fingerprint) {
            _fingerprints.remove(_fingerprintKey(w.jid, w.deviceId));
            return _blocked(
              PqBlockReason.unverifiableIdentity,
              requestedJids: requested,
              jid: w.jid,
              deviceId: w.deviceId,
            );
          }
        } catch (e) {
          _log.warning('trust lookup for ${w.jid}/${w.deviceId} failed: $e');
          return _blocked(
            PqBlockReason.trustStoreError,
            requestedJids: requested,
            jid: w.jid,
            deviceId: w.deviceId,
          );
        }
      }

      if (trust != null) {
        if (fingerprint == null) {
          return _blocked(
            PqBlockReason.unverifiableIdentity,
            requestedJids: requested,
            jid: w.jid,
            deviceId: w.deviceId,
          );
        }
        FingerprintTrust level;
        try {
          level = await trust.getTrust(w.jid, fingerprint);
        } catch (e) {
          _log.warning('trust read for ${w.jid}/${w.deviceId} failed: $e');
          return _blocked(
            PqBlockReason.trustStoreError,
            requestedJids: requested,
            jid: w.jid,
            deviceId: w.deviceId,
          );
        }
        switch (level) {
          case FingerprintTrust.untrusted:
            (excluded[w.jid] ??= {})[w.deviceId] = PqDeviceExclusion.untrusted;
            continue;
          case FingerprintTrust.undecided:
            return _blocked(
              PqBlockReason.undecidedDevice,
              requestedJids: requested,
              jid: w.jid,
              deviceId: w.deviceId,
            );
          case FingerprintTrust.blind:
          case FingerprintTrust.verified:
            break;
        }
      }

      allowed[w.jid]!.add(w.deviceId);
      if (!w.hasSession) {
        final device = w.device;
        if (device == null) {
          return _blocked(
            PqBlockReason.missingSessionMaterial,
            requestedJids: requested,
            jid: w.jid,
            deviceId: w.deviceId,
          );
        }
        newDevices.add(device);
      }
    }

    return PqPeerResolution(
      requestedJids: requested,
      announcedDeviceIds: announced,
      allowedDeviceIds: allowed,
      newDevices: newDevices,
      excluded: excluded,
    );
  }

  String? freshFingerprint(String jid, int deviceId, int generation) {
    final cached = _fingerprints[_fingerprintKey(jid, deviceId)];
    if (cached == null || !cached.isFresh(generation)) return null;
    return cached.fingerprint;
  }

  /// Classical IK fingerprint for trust (monocles §4.9.3 / §6.6).
  ///
  /// Hybrid is display-only once `<pq-ik>` is pinned — never the trust key.
  Future<String?> _stableFingerprint(PqDevice device) async {
    final pqIk = device.peerPqIdentityKey;
    if (pqIk == null || pqIk.isEmpty) return null;
    // Use the published public IK — remote devices have empty private halves.
    final ikRaw = await device.ikDh.pk.getBytes();
    return HEX.encode(Uint8List.fromList([0x05, ...ikRaw])).toLowerCase();
  }

  /// Pin-if-absent / refuse overwrite for [device]'s `<pq-ik>` (proto-XEP §4.9.2).
  ///
  /// Returns a block reason when the pinned key conflicts; null when OK.
  Future<PqBlockReason?> _enforcePqPin(PqDevice device) async {
    final store = pqPins;
    final pqIk = device.peerPqIdentityKey;
    if (store == null || pqIk == null || pqIk.isEmpty) return null;
    // Remote devices only hold the public IK; do not call ensureStores.
    final ikRaw = await device.ikDh.pk.getBytes();
    final ikFp = HEX.encode(Uint8List.fromList([0x05, ...ikRaw])).toLowerCase();
    final existing = await store.pinnedPqIdentity(device.jid, ikFp);
    if (existing != null) {
      if (!bytesEqual(existing, pqIk)) {
        _log.warning(
          'OMEMO2: pinned pq-ik conflicts for ${device.jid}/${device.id}',
        );
        return PqBlockReason.pqIdentityChanged;
      }
      return null;
    }
    final pinned = await store.pinIfAbsent(device.jid, ikFp, pqIk);
    if (!bytesEqual(pinned, pqIk)) {
      return PqBlockReason.pqIdentityChanged;
    }
    return null;
  }

  static bool _sameIds(Set<int>? cached, Set<int> current) =>
      cached != null &&
      cached.length == current.length &&
      cached.containsAll(current);

  static String _fingerprintKey(String jid, int deviceId) =>
      '$jid\x00$deviceId';

  PqPeerResolution _blocked(
    PqBlockReason reason, {
    required List<String> requestedJids,
    String? jid,
    int? deviceId,
  }) {
    return PqPeerResolution(
      requestedJids: requestedJids,
      announcedDeviceIds: const {},
      allowedDeviceIds: const {},
      newDevices: const [],
      excluded: const {},
      blockedReason: reason,
      blockedJid: jid,
      blockedDeviceId: deviceId,
    );
  }
}
