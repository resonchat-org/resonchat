// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Shared fingerprint *display* helpers (both tracks). Digests themselves live
// in omemo_dart: legacy → `axolotlFingerprint` / `AxolotlDevice.fingerprint`;
// hybrid → `hybridOmemo2Fingerprint` (`omemo_dart_omemo2`).

import 'package:cryptography/cryptography.dart';
import 'package:hex/hex.dart';

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
