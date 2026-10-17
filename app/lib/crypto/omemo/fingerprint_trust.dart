// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Per-(jid, fingerprint) trust + active/inactive, monocles-style.
//
// Rows live in [OmemoIdentities] (account DB), not Meta: trust decisions and
// announced-device bookkeeping are first-class data, not a key/value bag.
// Default for an unseen fingerprint is trusted (BTBV). Encrypt only to
// trusted *and* active devices (`isTrustedAndActive`).

import 'package:drift/drift.dart';

import '../../store/database.dart';

/// Whether we encrypt to this identity key (when it is also active).
enum FingerprintTrust {
  /// Blind-trust default / user confirmed.
  trusted,

  /// User turned trust off for this fingerprint only.
  untrusted,
}

/// Persists fingerprints, trust, and active/inactive in [OmemoIdentities].
class FingerprintTrustStore {
  FingerprintTrustStore(this._db);

  final AppDatabase _db;

  bool _legacyMigrated = false;

  /// Lowercase hex without whitespace — stable identity of a row.
  static String normalize(String fingerprint) =>
      fingerprint.replaceAll(RegExp(r'\s+'), '').toLowerCase();

  Future<void> _ensureLegacyMigrated() async {
    if (_legacyMigrated) return;
    _legacyMigrated = true;
    if (await _db.metaValue('fp_store_v2') == '1') return;

    final trustByKey = <String, FingerprintTrust>{};
    for (final row in await _db.metaEntriesWithPrefix('fp_trust:')) {
      // fp_trust:<jid>:<fingerprint>
      final rest = row.key.substring('fp_trust:'.length);
      final split = rest.indexOf(':');
      if (split <= 0) continue;
      final jid = rest.substring(0, split).toLowerCase();
      final fp = normalize(rest.substring(split + 1));
      if (fp.isEmpty) continue;
      trustByKey['$jid\x00$fp'] = row.value == 'untrusted'
          ? FingerprintTrust.untrusted
          : FingerprintTrust.trusted;
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    for (final row in await _db.metaEntriesWithPrefix('fp_dev:')) {
      // fp_dev:pq|ax:<jid>:<deviceId>
      final parts = row.key.split(':');
      if (parts.length < 4) continue;
      final omemo2 = parts[1] == 'pq';
      final jid = parts[2].toLowerCase();
      final deviceId = int.tryParse(parts[3]);
      if (deviceId == null) continue;
      final fp = normalize(row.value);
      if (fp.isEmpty) continue;
      final trust = trustByKey['$jid\x00$fp'] ?? FingerprintTrust.trusted;
      await _db
          .into(_db.omemoIdentities)
          .insertOnConflictUpdate(
            OmemoIdentitiesCompanion.insert(
              bareJid: jid,
              fingerprint: fp,
              deviceId: deviceId,
              omemo2: omemo2,
              trust: trust == FingerprintTrust.trusted
                  ? 'trusted'
                  : 'untrusted',
              active: true,
              lastActivation: Value(now),
            ),
          );
    }

    // Trust-only rows (no device mapping yet) still matter for BTBV continuity.
    for (final entry in trustByKey.entries) {
      final nul = entry.key.indexOf('\x00');
      if (nul < 0) continue;
      final jid = entry.key.substring(0, nul);
      final fp = entry.key.substring(nul + 1);
      final existing =
          await (_db.select(
                _db.omemoIdentities,
              )..where((t) => t.bareJid.equals(jid) & t.fingerprint.equals(fp)))
              .getSingleOrNull();
      if (existing != null) continue;
      await _db
          .into(_db.omemoIdentities)
          .insertOnConflictUpdate(
            OmemoIdentitiesCompanion.insert(
              bareJid: jid,
              fingerprint: fp,
              deviceId: 0,
              omemo2: false,
              trust: entry.value == FingerprintTrust.trusted
                  ? 'trusted'
                  : 'untrusted',
              active: false,
              lastActivation: const Value(0),
            ),
          );
    }

    for (final row in await _db.metaEntriesWithPrefix('fp_trust:')) {
      await _db.deleteMetaValue(row.key);
    }
    for (final row in await _db.metaEntriesWithPrefix('fp_dev:')) {
      await _db.deleteMetaValue(row.key);
    }
    await _db.setMetaValue('fp_store_v2', '1');
  }

  Future<OmemoIdentity?> _row(String jid, String fingerprint) async {
    await _ensureLegacyMigrated();
    final bare = jid.toLowerCase();
    final fp = normalize(fingerprint);
    return (_db.select(_db.omemoIdentities)
          ..where((t) => t.bareJid.equals(bare) & t.fingerprint.equals(fp)))
        .getSingleOrNull();
  }

  /// Missing row → [FingerprintTrust.trusted] (BTBV).
  Future<FingerprintTrust> getTrust(String jid, String fingerprint) async {
    final row = await _row(jid, fingerprint);
    if (row?.trust == 'untrusted') return FingerprintTrust.untrusted;
    return FingerprintTrust.trusted;
  }

  Future<void> setTrust(
    String jid,
    String fingerprint,
    FingerprintTrust trust,
  ) async {
    await _ensureLegacyMigrated();
    final bare = jid.toLowerCase();
    final fp = normalize(fingerprint);
    final existing = await _row(bare, fp);
    final label = trust == FingerprintTrust.trusted ? 'trusted' : 'untrusted';
    if (existing == null) {
      await _db
          .into(_db.omemoIdentities)
          .insert(
            OmemoIdentitiesCompanion.insert(
              bareJid: bare,
              fingerprint: fp,
              deviceId: 0,
              omemo2: false,
              trust: label,
              active: false,
              lastActivation: const Value(0),
            ),
          );
      return;
    }
    await (_db.update(_db.omemoIdentities)
          ..where((t) => t.bareJid.equals(bare) & t.fingerprint.equals(fp)))
        .write(OmemoIdentitiesCompanion(trust: Value(label)));
  }

  /// Trusted only — does not require active (for UI / migration checks).
  Future<bool> mayEncryptTo(String jid, String fingerprint) async =>
      await getTrust(jid, fingerprint) == FingerprintTrust.trusted;

  /// monocles `isTrustedAndActive`: skip untrusted **or** inactive devices.
  Future<bool> mayEncryptToActive(String jid, String fingerprint) async {
    final row = await _row(jid, fingerprint);
    if (row == null) return true; // BTBV until remembered
    if (row.trust == 'untrusted') return false;
    return row.active;
  }

  /// Cache deviceId → fingerprint, mark active, seed BTBV trust if unseen.
  Future<void> rememberDevice({
    required String jid,
    required int deviceId,
    required String fingerprint,
    required bool omemo2,
  }) async {
    await _ensureLegacyMigrated();
    final bare = jid.toLowerCase();
    final fp = normalize(fingerprint);
    if (fp.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final existing = await _row(bare, fp);
    final trust = existing?.trust == 'untrusted' ? 'untrusted' : 'trusted';
    final wasInactive = existing != null && !existing.active;
    final lastAct = existing == null || wasInactive
        ? now
        : existing.lastActivation;

    await _db
        .into(_db.omemoIdentities)
        .insertOnConflictUpdate(
          OmemoIdentitiesCompanion.insert(
            bareJid: bare,
            fingerprint: fp,
            deviceId: deviceId,
            omemo2: omemo2,
            trust: trust,
            active: true,
            lastActivation: Value(lastAct),
          ),
        );

    // Same PEP device id, different fingerprint → old identity is superseded.
    if (deviceId != 0) {
      final rivals =
          await (_db.select(_db.omemoIdentities)..where(
                (t) =>
                    t.bareJid.equals(bare) &
                    t.omemo2.equals(omemo2) &
                    t.deviceId.equals(deviceId) &
                    t.fingerprint.isNotValue(fp),
              ))
              .get();
      for (final rival in rivals) {
        if (!rival.active) continue;
        await (_db.update(_db.omemoIdentities)..where(
              (t) =>
                  t.bareJid.equals(rival.bareJid) &
                  t.fingerprint.equals(rival.fingerprint),
            ))
            .write(const OmemoIdentitiesCompanion(active: Value(false)));
      }
    }
  }

  Future<String?> fingerprintOfDevice(
    String jid,
    int deviceId, {
    required bool omemo2,
  }) async {
    await _ensureLegacyMigrated();
    final bare = jid.toLowerCase();
    final rows =
        await (_db.select(_db.omemoIdentities)..where(
              (t) =>
                  t.bareJid.equals(bare) &
                  t.omemo2.equals(omemo2) &
                  t.deviceId.equals(deviceId),
            ))
            .get();
    if (rows.isEmpty) return null;
    // Prefer the active row when a device id briefly maps to two fps.
    rows.sort((a, b) {
      final byActive = (b.active ? 1 : 0).compareTo(a.active ? 1 : 0);
      if (byActive != 0) return byActive;
      return b.lastActivation.compareTo(a.lastActivation);
    });
    return rows.first.fingerprint;
  }

  /// All known identities for [jid] (active and inactive), optional stack filter.
  Future<List<OmemoIdentity>> identitiesFor(String jid, {bool? omemo2}) async {
    await _ensureLegacyMigrated();
    final bare = jid.toLowerCase();
    final query = _db.select(_db.omemoIdentities)
      ..where((t) {
        final j = t.bareJid.equals(bare);
        if (omemo2 == null) return j;
        return j & t.omemo2.equals(omemo2);
      });
    final rows = await query.get();
    rows.sort((a, b) {
      final byActive = (b.active ? 1 : 0).compareTo(a.active ? 1 : 0);
      if (byActive != 0) return byActive;
      final byStack = (a.omemo2 ? 1 : 0).compareTo(b.omemo2 ? 1 : 0);
      if (byStack != 0) return byStack;
      return a.deviceId.compareTo(b.deviceId);
    });
    return rows;
  }

  /// After a reliable PEP device-list read: mark announced ids active, others
  /// on this stack inactive. Does nothing useful with an empty failed fetch —
  /// callers must only invoke when the list was readable.
  Future<void> syncAnnouncedDevices({
    required String jid,
    required Iterable<int> announcedIds,
    required bool omemo2,
  }) async {
    await _ensureLegacyMigrated();
    final bare = jid.toLowerCase();
    final announced = announcedIds.toSet();
    final known = await identitiesFor(bare, omemo2: omemo2);
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final row in known) {
      if (row.deviceId == 0) continue;
      final shouldActive = announced.contains(row.deviceId);
      if (row.active == shouldActive) continue;
      await (_db.update(_db.omemoIdentities)..where(
            (t) =>
                t.bareJid.equals(row.bareJid) &
                t.fingerprint.equals(row.fingerprint),
          ))
          .write(
            OmemoIdentitiesCompanion(
              active: Value(shouldActive),
              lastActivation: shouldActive && !row.active
                  ? Value(now)
                  : const Value.absent(),
            ),
          );
    }
  }
}

/// One peer device row for the security / trust UI.
class PeerFingerprintRow {
  const PeerFingerprintRow({
    required this.peerJid,
    required this.deviceId,
    required this.fingerprint,
    required this.omemo2,
    required this.trusted,
    this.active = true,
  });

  /// Bare JID that owns this identity key (1:1 peer, or MUC member real JID).
  final String peerJid;

  final int deviceId;
  final String fingerprint;
  final bool omemo2;
  final bool trusted;

  /// Still on the peer's announced device list for this stack.
  final bool active;
}
