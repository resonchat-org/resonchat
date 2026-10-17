// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// monocles PqBundle.transcript + kemBinding (proto-XEP §4.9.1).

import 'dart:convert';
import 'dart:typed_data';

import 'package:pqcrypto/pqcrypto.dart';

import 'protocol.dart';

/// One ML-KEM one-time prekey as it appears in the bundle document order.
class KemOpkWire {
  const KemOpkWire({required this.id, required this.publicKey});

  final int id;

  /// Raw wire bytes as base64-decoded from `<kem-pk>` (tagged serialize).
  final Uint8List publicKey;
}

/// SHA3-512 KEM-BINDING digest (64 bytes).
///
/// Known-answer (proto-XEP §4.9.1): kemSpkId=1, KEM-SPK=0xAA×4, two OPKs
/// (id=2, 0xBB×3) and (id=3, 0xCC×5) →
/// `7f93e762…3c8c98f2`.
Uint8List kemBinding({
  required int kemSpkId,
  required Uint8List kemSpk,
  required List<KemOpkWire> oneTimeKeys,
}) {
  final manifest = _kemManifest(oneTimeKeys);
  final buf = BytesBuilder(copy: false);
  buf.add(utf8.encode(omemo2KemBindingLabel));
  _appendLp(buf, utf8.encode(omemo2KemAlgorithm));
  _appendU32(buf, kemSpkId);
  _appendLp(buf, kemSpk);
  _appendLp(buf, manifest);
  return sha3512(buf.toBytes());
}

Uint8List _kemManifest(List<KemOpkWire> keys) {
  if (keys.isEmpty) return Uint8List(64);
  final buf = BytesBuilder(copy: false);
  for (final k in keys) {
    _appendU32(buf, k.id);
    _appendLp(buf, k.publicKey);
  }
  return sha3512(buf.toBytes());
}

/// Identity transcript signed by ML-DSA-87 under context [omemo2PqIdContext].
///
/// [ik] and [spk] are libsignal serialize form (33 bytes, leading `0x05`).
/// [pqIk] is raw ML-DSA-87 verification key (2592 bytes).
Uint8List pqBundleTranscript({
  required Uint8List ik,
  required Uint8List pqIk,
  required int signedPreKeyId,
  required Uint8List spk,
  required Uint8List kemBindingDigest,
}) {
  final buf = BytesBuilder(copy: false);
  buf.add(utf8.encode(omemo2PqBundleTranscriptLabel));
  _appendLp(buf, utf8.encode(omemo2PqIkAlgorithm));
  _appendLp(buf, ik);
  _appendLp(buf, pqIk);
  _appendU32(buf, signedPreKeyId);
  _appendLp(buf, spk);
  _appendLp(buf, kemBindingDigest);
  return buf.toBytes();
}

void _appendLp(BytesBuilder buf, List<int> value) {
  _appendU32(buf, value.length);
  buf.add(value);
}

void _appendU32(BytesBuilder buf, int value) {
  final b = ByteData(4)..setUint32(0, value, Endian.big);
  buf.add(b.buffer.asUint8List());
}
