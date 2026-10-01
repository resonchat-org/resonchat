// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Identity-key fingerprints. Shared by both tracks (invariant 4 in
// docs/01-overview.md): users compare the same fingerprint in any client.

import 'package:cryptography/cryptography.dart';
import 'package:hex/hex.dart';

/// SHA-256 of raw key bytes, lowercase hex.
Future<String> sha256Hex(List<int> bytes) async {
  final digest = await Sha256().hash(bytes);
  return HEX.encode(digest.bytes);
}

/// Groups a 64-char hex fingerprint as `xxxxxxxx xxxxxxxx ...`
/// (8 groups of 8), the layout used on the verification page.
String formatFingerprint(String hexDigest) {
  final clean = hexDigest.replaceAll(RegExp(r'\s+'), '').toLowerCase();
  final groups = <String>[];
  for (var i = 0; i < clean.length; i += 8) {
    final end = (i + 8 < clean.length) ? i + 8 : clean.length;
    groups.add(clean.substring(i, end));
  }
  return groups.join(' ');
}
