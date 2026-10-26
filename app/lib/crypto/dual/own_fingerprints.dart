// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Own-device fingerprint pair for UI (monocles hybrid + legacy).

import 'dart:typed_data';

import 'package:omemo_dart/omemo_dart_axolotl.dart';
import 'package:omemo_dart/omemo_dart_omemo2.dart' show hybridOmemo2Fingerprint;

import 'package:resonchat/persistence/pq_identity_store.dart';

/// Hybrid (OMEMO2 display) and legacy (classical serialize hex) fingerprints.
class OwnFingerprints {
  const OwnFingerprints({required this.hybrid, required this.legacy});

  /// SHA3-512 hybrid hex (128 chars). Display with [formatFingerprint].
  final String hybrid;

  /// Classical IdentityKey.serialize() hex (66 chars, leading `05`).
  /// Display with [formatFingerprint] (strips `05`).
  final String legacy;
}

/// Resolve both fingerprints.
///
/// [legacyDevice] is the A-track / Conversations identity.
/// [omemo2IkSerialized] is the OMEMO2 classical `IdentityKey.serialize()`
/// (33 bytes with `0x05`); when null, hybrid falls back to the legacy IK
/// (only for cold start before OMEMO2 init).
Future<OwnFingerprints> loadOwnFingerprints({
  required AxolotlDevice legacyDevice,
  required PqIdentityStore pqStore,
  List<int>? omemo2IkSerialized,
}) async {
  final pqIk = await pqStore.publicKey();
  // Never fall back to the A-track IK for hybrid — stacks must stay separate
  // (monocles). Without an OMEMO2 IK, hybrid is empty until B-track inits.
  final hybrid = omemo2IkSerialized == null
      ? ''
      : hybridOmemo2Fingerprint(Uint8List.fromList(omemo2IkSerialized), pqIk);
  return OwnFingerprints(
    hybrid: hybrid,
    legacy: await legacyDevice.fingerprint,
  );
}
