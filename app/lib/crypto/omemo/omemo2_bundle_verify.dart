// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// monocles `PqBundle.verify` + `IqParser.omemo2PqIdentity` for fetched bundles.
// Both transcript signatures (ML-DSA-87 and classical IK) must validate before
// we treat a peer as OMEMO2-capable or build a session.

import 'dart:convert';
import 'dart:typed_data';

import 'package:libsignal/libsignal.dart';
import 'package:logging/logging.dart';
import 'package:omemo_dart/omemo_dart_omemo2.dart' show omemo2EnsureLibSignal;

import '../pq/kem_wire.dart';
import 'bundle_codec.dart';

final _log = Logger('Omemo2BundleVerify');

/// Wire lengths monocles `IqParser` enforces (ML-DSA-87 + XEdDSA).
const int omemo2PqIkLength = 2592;
const int omemo2PqSigLength = 4627;
const int omemo2IkSigLength = 64;

/// Parsed hybrid identity from a bundle, or null when monocles would refuse.
class Omemo2PqIdentity {
  const Omemo2PqIdentity({
    required this.pqIk,
    required this.pqSig,
    required this.ikSig,
  });

  final Uint8List pqIk;
  final Uint8List pqSig;
  final Uint8List ikSig;
}

/// monocles `IqParser.omemo2PqIdentity`: missing/wrong-length → null.
Omemo2PqIdentity? parseOmemo2PqIdentity(Omemo2Bundle bundle) {
  if (!bundle.hasPqIdentity) {
    _log.warning(
      'OMEMO2: bundle ${bundle.jid}/${bundle.deviceId} missing '
      'pq-ik/pq-sig/ik-sig (rev may predate v4)',
    );
    return null;
  }
  try {
    final pqIk = base64Decode(omemo2WireB64(bundle.pqIk));
    final pqSig = base64Decode(omemo2WireB64(bundle.pqSig));
    final ikSig = base64Decode(omemo2WireB64(bundle.ikSig));
    if (pqIk.length != omemo2PqIkLength ||
        pqSig.length != omemo2PqSigLength ||
        ikSig.length != omemo2IkSigLength) {
      _log.warning(
        'OMEMO2: pq-ik/pq-sig/ik-sig wrong length for '
        '${bundle.jid}/${bundle.deviceId}',
      );
      return null;
    }
    return Omemo2PqIdentity(
      pqIk: Uint8List.fromList(pqIk),
      pqSig: Uint8List.fromList(pqSig),
      ikSig: Uint8List.fromList(ikSig),
    );
  } catch (e) {
    _log.warning('OMEMO2: invalid pq-ik/pq-sig/ik-sig: $e');
    return null;
  }
}

/// null when [bundle] matches monocles `PqBundle.verify`. Otherwise a reason
/// safe to log (no key material).
Future<String?> omemo2BundleRefusal(Omemo2Bundle bundle) async {
  final who = '${bundle.jid}/${bundle.deviceId}';
  final pq = parseOmemo2PqIdentity(bundle);
  if (pq == null) {
    return 'bundle $who missing/invalid pq-ik/pq-sig/ik-sig '
        '(pqIk=${bundle.pqIk.length} chars, pqSig=${bundle.pqSig.length} '
        'chars, ikSig=${bundle.ikSig.length} chars)';
  }

  await omemo2EnsureLibSignal();

  Uint8List kemSpkTagged;
  try {
    kemSpkTagged = Uint8List.fromList(
      base64Decode(omemo2WireB64(bundle.kemSpk)),
    );
  } catch (e) {
    return 'bundle $who kem-spk base64: $e';
  }
  if (!isMlKem1024PublicKey(kemSpkTagged)) {
    return 'bundle $who kem-spk is not ML-KEM-1024';
  }

  // monocles `omemo2KemPreKeys`: document order, skip a key that is not
  // ML-KEM-1024 rather than folding it into the binding.
  final oneTime = <KemOneTimeKey>[];
  for (final e in bundle.kemPrekeys.entries) {
    Uint8List raw;
    try {
      raw = Uint8List.fromList(base64Decode(omemo2WireB64(e.value)));
    } catch (err) {
      _log.warning('OMEMO2: skip kem-pk id=${e.key} ($who): $err');
      continue;
    }
    if (!isMlKem1024PublicKey(raw)) {
      _log.warning('OMEMO2: skip kem-pk id=${e.key} ($who): not ML-KEM-1024');
      continue;
    }
    oneTime.add(KemOneTimeKey(id: e.key, publicKey: raw));
  }

  final binding = pqKemBinding(
    kemSignedPreKeyId: bundle.kemSpkId,
    kemSignedPreKeyPublic: kemSpkTagged,
    oneTime: oneTime,
  );
  final spkRaw = base64Decode(omemo2WireB64(bundle.spk));
  if (spkRaw.length != 32 && !(spkRaw.length == 33 && spkRaw.first == 0x05)) {
    return 'bundle $who spk length ${spkRaw.length}';
  }
  final spkSerialized = spkRaw.length == 33
      ? Uint8List.fromList(spkRaw)
      : Uint8List.fromList([0x05, ...spkRaw]);
  final transcript = pqBundleTranscript(
    identityKey: bundle.ikSerialized,
    pqIdentityKey: pq.pqIk,
    signedPreKeyId: bundle.spkId,
    signedPreKeyPublic: spkSerialized,
    kemBinding: binding,
  );

  // Same routine as monocles `PqBundle.verify` (libsignal, not a second
  // ML-DSA implementation).
  final bool pqOk;
  try {
    pqOk = PqIdentityKey.deserialize(bytes: pq.pqIk).verify(
      message: transcript,
      signature: PqSignature.deserialize(bytes: pq.pqSig),
    );
  } catch (e) {
    return 'bundle $who pq-sig verify error: $e';
  }
  if (!pqOk) {
    return 'bundle $who invalid pq-sig '
        '(kem one-time keys in binding: ${oneTime.length})';
  }

  try {
    final ikOk = PublicKey.deserialize(bytes: bundle.ikSerialized.toList())
        .verify(message: transcript.toList(), signature: pq.ikSig.toList());
    if (!ikOk) return 'bundle $who invalid ik-sig';
  } catch (e) {
    return 'bundle $who ik-sig verify error: $e';
  }
  return null;
}

/// monocles `PqBundle.verify`: both signatures over the v4 transcript.
Future<bool> verifyOmemo2Bundle(Omemo2Bundle bundle) async {
  final reason = await omemo2BundleRefusal(bundle);
  if (reason != null) {
    _log.warning('OMEMO2: $reason');
    return false;
  }
  return true;
}
