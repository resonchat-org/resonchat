// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Per-(jid, fingerprint) trust + active/inactive, aligned with Gajim.
//
// Gajim `Trust` (const.py): UNTRUSTED / UNDECIDED / BLIND / VERIFIED.
// Encrypt only to BLIND and VERIFIED (`is_trusted`). New devices get BLIND
// when the blind-trust preference is on (and the contact has no cautious
// identities yet), otherwise UNDECIDED — same as Gajim `get_default_trust`.
//
// Rows live in [OmemoIdentities]. Legacy wire `trusted` reads as [blind].

import 'package:drift/drift.dart';

import 'package:resonchat/persistence/database.dart';

/// Gajim `Trust` — four levels, stored as the enum [name] in SQL.
enum FingerprintTrust {
  /// Gajim UNTRUSTED — do not encrypt to this identity.
  untrusted,

  /// Gajim UNDECIDED — not yet decided; do not encrypt.
  undecided,

  /// Gajim BLIND — blindly trusted until verified.
  blind,

  /// Gajim VERIFIED — compared out-of-band.
  verified;

  /// Wire form in [OmemoIdentities.trust] / `enc_mode` trust suffix.
  String get wire => name;

  /// Whether outbound encryption may include this identity (Gajim
  /// `is_trusted`: VERIFIED or BLIND).
  bool get allowsEncrypt =>
      this == FingerprintTrust.blind || this == FingerprintTrust.verified;

  /// Parses a stored label. Legacy `trusted` → [blind].
  static FingerprintTrust parse(String? raw) => switch (raw?.toLowerCase()) {
    'untrusted' => FingerprintTrust.untrusted,
    'undecided' => FingerprintTrust.undecided,
    'verified' => FingerprintTrust.verified,
    'blind' || 'trusted' => FingerprintTrust.blind,
    _ => FingerprintTrust.undecided,
  };

  /// Lower trust wins when a message encrypts to several devices.
  static FingerprintTrust minOf(Iterable<FingerprintTrust> values) {
    var best = FingerprintTrust.verified;
    var any = false;
    for (final t in values) {
      any = true;
      if (t.index < best.index) best = t;
    }
    return any ? best : FingerprintTrust.undecided;
  }
}

/// How [FingerprintTrustStore] picks trust for a newly seen identity.
typedef BlindTrustPolicy = Future<bool> Function();

/// Persists fingerprints, trust, and active/inactive in [OmemoIdentities].
class FingerprintTrustStore {
  FingerprintTrustStore(this._db, {BlindTrustPolicy? blindTrustEnabled})
    : _blindTrustEnabled = blindTrustEnabled ?? (() async => true);

  final AppDatabase _db;
  final BlindTrustPolicy _blindTrustEnabled;

  bool _legacyMigrated = false;

  /// Lowercase hex without whitespace — stable identity of a row.
  static String normalize(String fingerprint) =>
      fingerprint.replaceAll(RegExp(r'\s+'), '').toLowerCase();

  Future<void> _ensureLegacyMigrated() async {
    if (_legacyMigrated) return;
    _legacyMigrated = true;
    // Always collapse the old two-level `trusted` label onto Gajim BLIND.
    await _rewriteLegacyTrustedLabel();
    if (await _db.metaValue('fp_store_v2') == '1') return;

    final trustByKey = <String, FingerprintTrust>{};
    for (final row in await _db.metaEntriesWithPrefix('fp_trust:')) {
      final rest = row.key.substring('fp_trust:'.length);
      final split = rest.indexOf(':');
      if (split <= 0) continue;
      final jid = rest.substring(0, split).toLowerCase();
      final fp = normalize(rest.substring(split + 1));
      if (fp.isEmpty) continue;
      trustByKey['$jid\x00$fp'] = FingerprintTrust.parse(row.value);
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    for (final row in await _db.metaEntriesWithPrefix('fp_dev:')) {
      final parts = row.key.split(':');
      if (parts.length < 4) continue;
      final omemo2 = parts[1] == 'pq';
      final jid = parts[2].toLowerCase();
      final deviceId = int.tryParse(parts[3]);
      if (deviceId == null) continue;
      final fp = normalize(row.value);
      if (fp.isEmpty) continue;
      final trust = trustByKey['$jid\x00$fp'] ?? FingerprintTrust.blind;
      await _db
          .into(_db.omemoIdentities)
          .insertOnConflictUpdate(
            OmemoIdentitiesCompanion.insert(
              bareJid: jid,
              fingerprint: fp,
              deviceId: deviceId,
              omemo2: omemo2,
              trust: trust.wire,
              active: true,
              lastActivation: Value(now),
            ),
          );
    }

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
              trust: entry.value.wire,
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
    // Rewrite legacy `trusted` → `blind` in already-migrated identity rows.
    await _rewriteLegacyTrustedLabel();
    await _db.setMetaValue('fp_store_v2', '1');
  }

  Future<void> _rewriteLegacyTrustedLabel() async {
    await (_db.update(_db.omemoIdentities)
          ..where((t) => t.trust.equals('trusted')))
        .write(const OmemoIdentitiesCompanion(trust: Value('blind')));
  }

  Future<OmemoIdentity?> _row(String jid, String fingerprint) async {
    await _ensureLegacyMigrated();
    final bare = jid.toLowerCase();
    final fp = normalize(fingerprint);
    return (_db.select(_db.omemoIdentities)
          ..where((t) => t.bareJid.equals(bare) & t.fingerprint.equals(fp)))
        .getSingleOrNull();
  }

  /// Gajim `get_default_trust` for a newly seen identity under [jid].
  Future<FingerprintTrust> defaultTrustFor(String jid) async {
    await _ensureLegacyMigrated();
    if (!await _blindTrustEnabled()) return FingerprintTrust.undecided;
    final bare = jid.toLowerCase();
    final cautious =
        await (_db.select(_db.omemoIdentities)..where(
              (t) =>
                  t.bareJid.equals(bare) &
                  (t.trust.equals('untrusted') | t.trust.equals('undecided')),
            ))
            .get();
    if (cautious.isEmpty) return FingerprintTrust.blind;
    return FingerprintTrust.undecided;
  }

  /// Missing row → default as if newly seen (blind or undecided by policy).
  Future<FingerprintTrust> getTrust(String jid, String fingerprint) async {
    final row = await _row(jid, fingerprint);
    if (row == null) return defaultTrustFor(jid);
    return FingerprintTrust.parse(row.trust);
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
    if (existing == null) {
      await _db
          .into(_db.omemoIdentities)
          .insert(
            OmemoIdentitiesCompanion.insert(
              bareJid: bare,
              fingerprint: fp,
              deviceId: 0,
              omemo2: false,
              trust: trust.wire,
              active: false,
              lastActivation: const Value(0),
            ),
          );
      return;
    }
    await (_db.update(_db.omemoIdentities)
          ..where((t) => t.bareJid.equals(bare) & t.fingerprint.equals(fp)))
        .write(OmemoIdentitiesCompanion(trust: Value(trust.wire)));
  }

  /// Trusted for encryption (blind or verified) — not active-gated.
  Future<bool> mayEncryptTo(String jid, String fingerprint) async =>
      (await getTrust(jid, fingerprint)).allowsEncrypt;

  /// Gajim-style: skip untrusted / undecided **or** inactive devices.
  Future<bool> mayEncryptToActive(String jid, String fingerprint) async {
    final row = await _row(jid, fingerprint);
    if (row == null) {
      // No row yet: encrypt only when the default would be blind.
      return (await defaultTrustFor(jid)).allowsEncrypt;
    }
    if (!FingerprintTrust.parse(row.trust).allowsEncrypt) return false;
    return row.active;
  }

  /// Lowest trust among active identities on [omemo2] for [jid], for message
  /// labels. Null when none are active.
  Future<FingerprintTrust?> aggregateActiveTrust(
    String jid, {
    required bool omemo2,
  }) async {
    final rows = await identitiesFor(jid, omemo2: omemo2);
    final active = [
      for (final r in rows)
        if (r.active && r.deviceId != 0) FingerprintTrust.parse(r.trust),
    ];
    if (active.isEmpty) return null;
    return FingerprintTrust.minOf(active);
  }

  /// Cache deviceId → fingerprint, mark active, seed default trust if unseen.
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
    final trust = existing != null
        ? FingerprintTrust.parse(existing.trust)
        : await defaultTrustFor(bare);
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
            trust: trust.wire,
            active: true,
            lastActivation: Value(lastAct),
          ),
        );

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
    rows.sort((a, b) {
      final byActive = (b.active ? 1 : 0).compareTo(a.active ? 1 : 0);
      if (byActive != 0) return byActive;
      return b.lastActivation.compareTo(a.lastActivation);
    });
    return rows.first.fingerprint;
  }

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
    required this.trust,
    this.active = true,
  });

  final String peerJid;
  final int deviceId;
  final String fingerprint;
  final bool omemo2;
  final FingerprintTrust trust;
  final bool active;

  PeerFingerprintRow copyWith({FingerprintTrust? trust, bool? active}) =>
      PeerFingerprintRow(
        peerJid: peerJid,
        deviceId: deviceId,
        fingerprint: fingerprint,
        omemo2: omemo2,
        trust: trust ?? this.trust,
        active: active ?? this.active,
      );
}
