// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Never-overwrite pin of peer `<pq-ik>` keyed by classical IK fingerprint
// (monocles `DatabaseBackend.pinOmemo2PqIdentityIfAbsent`).

import 'package:drift/drift.dart';

import 'package:resonchat/crypto/omemo2/pq_auth.dart';
import 'package:resonchat/persistence/database.dart';

/// Persists OMEMO2 PQ identity pins in [Omemo2PqPins].
class Omemo2PqPinStore implements PqIdentityPins {
  Omemo2PqPinStore(this._db);

  final AppDatabase _db;

  static String _normJid(String jid) => jid.toLowerCase();

  static String _normFp(String fingerprint) =>
      fingerprint.replaceAll(RegExp(r'\s+'), '').toLowerCase();

  @override
  Future<Uint8List?> pinnedPqIdentity(String name, String ikFingerprint) async {
    final bare = _normJid(name);
    final fp = _normFp(ikFingerprint);
    final row =
        await (_db.select(_db.omemo2PqPins)..where(
              (t) => t.bareJid.equals(bare) & t.classicalFingerprint.equals(fp),
            ))
            .getSingleOrNull();
    if (row == null) return null;
    return Uint8List.fromList(row.pqIk);
  }

  @override
  Future<Uint8List> pinIfAbsent(
    String name,
    String ikFingerprint,
    Uint8List pqIdentityKey,
  ) async {
    final bare = _normJid(name);
    final fp = _normFp(ikFingerprint);
    // INSERT OR IGNORE — a concurrent pin is never overwritten.
    await _db
        .into(_db.omemo2PqPins)
        .insert(
          Omemo2PqPinsCompanion.insert(
            bareJid: bare,
            classicalFingerprint: fp,
            pqIk: pqIdentityKey,
          ),
          mode: InsertMode.insertOrIgnore,
        );
    final pinned = await pinnedPqIdentity(bare, fp);
    // Row must exist after insert-or-ignore (either ours or a prior pin).
    return pinned ?? Uint8List.fromList(pqIdentityKey);
  }

  /// Replace pin — only for out-of-band hybrid fingerprint verification.
  Future<void> pinReplace(
    String name,
    String ikFingerprint,
    Uint8List pqIdentityKey,
  ) async {
    final bare = _normJid(name);
    final fp = _normFp(ikFingerprint);
    await _db
        .into(_db.omemo2PqPins)
        .insertOnConflictUpdate(
          Omemo2PqPinsCompanion.insert(
            bareJid: bare,
            classicalFingerprint: fp,
            pqIk: pqIdentityKey,
          ),
        );
  }

  Future<void> unpin(String name, String ikFingerprint) async {
    final bare = _normJid(name);
    final fp = _normFp(ikFingerprint);
    await (_db.delete(_db.omemo2PqPins)..where(
          (t) => t.bareJid.equals(bare) & t.classicalFingerprint.equals(fp),
        ))
        .go();
  }
}
