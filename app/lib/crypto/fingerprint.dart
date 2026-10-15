// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Identity-key fingerprints. Stacks are separate (monocles):
//   • Hybrid — SHA3-512 of OMEMO2 classical IK (0x05‖32) + ML-DSA-87 PQ IK
//   • Legacy — A-track Conversations IdentityKey.serialize() (strip leading 05)

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:hex/hex.dart';
import 'package:pqcrypto/pqcrypto.dart';

/// Domain-separation label used by monocles
/// `CryptoHelper.hybridOmemo2Fingerprint`.
final Uint8List kHybridOmemo2FpLabel = Uint8List.fromList(
  ascii.encode('monocles:omemo2:ik:v2'),
);

/// SHA-256 of raw key bytes, lowercase hex.
Future<String> sha256Hex(List<int> bytes) async {
  final digest = await Sha256().hash(bytes);
  return HEX.encode(digest.bytes);
}

/// Groups hex for display as `xxxxxxxx xxxxxxxx ...` (8 groups of 8).
///
/// Conversations `CryptoHelper.prettifyFingerprint(fp.substring(2))`: drop the
/// leading DJB Curve type byte (`05`) from a 66-char Signal serialize hex,
/// then insert spaces every 8 characters.
///
/// Hybrid (128-char SHA3-512) digests are not stripped — only the classical
/// 33-byte identity serialize form uses the `05` prefix.
String formatFingerprint(String hexDigest) {
  var clean = hexDigest.replaceAll(RegExp(r'\s+'), '').toLowerCase();
  if (clean.length == 66 && clean.startsWith('05')) {
    clean = clean.substring(2);
  }
  final groups = <String>[];
  for (var i = 0; i < clean.length; i += 8) {
    final end = (i + 8 < clean.length) ? i + 8 : clean.length;
    groups.add(clean.substring(i, end));
  }
  return groups.join(' ');
}

/// monocles `CryptoHelper.hybridOmemo2Fingerprint`: SHA3-512 over
/// `monocles:omemo2:ik:v2` ‖ len32(classical IK) ‖ classical IK ‖
/// len32(pq IK) ‖ pq IK. Returns lowercase hex (128 chars).
String hybridOmemo2Fingerprint(Uint8List identityKey, Uint8List pqIdentityKey) {
  final buf = BytesBuilder(copy: false);
  buf.add(kHybridOmemo2FpLabel);
  _appendLengthPrefixed(buf, identityKey);
  _appendLengthPrefixed(buf, pqIdentityKey);
  return HEX.encode(sha3512(buf.toBytes()));
}

void _appendLengthPrefixed(BytesBuilder buf, Uint8List value) {
  final len = ByteData(4)..setInt32(0, value.length, Endian.big);
  buf.add(len.buffer.asUint8List());
  buf.add(value);
}
