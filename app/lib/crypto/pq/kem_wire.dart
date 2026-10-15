// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// libsignal-style ML-KEM public-key serialization for monocles OMEMO2:
// one type byte + raw FIPS 203 public key.

import 'dart:typed_data';

import '../omemo/protocol.dart';
import 'mlkem.dart';

/// Encode a raw ML-KEM-1024 public key for the wire (`0x0A ‖ pk`).
Uint8List serializeMlKem1024PublicKey(List<int> rawPublicKey) {
  if (rawPublicKey.length != MlKem1024.publicKeyLength) {
    throw ArgumentError(
      'ML-KEM-1024 public key must be ${MlKem1024.publicKeyLength} bytes',
    );
  }
  return Uint8List.fromList([mlKem1024Tag, ...rawPublicKey]);
}

/// Decode a wire ML-KEM public key. Refuses Round-3 Kyber (`0x08`) and
/// anything that is not ML-KEM-1024 (`0x0A`).
Uint8List parseMlKem1024PublicKey(List<int> serialized) {
  if (serialized.isEmpty) {
    throw FormatException('empty KEM public key');
  }
  final tag = serialized[0];
  if (tag == kyber1024Round3Tag) {
    throw FormatException('Round-3 Kyber-1024 keys are refused (tag 0x08)');
  }
  if (tag != mlKem1024Tag) {
    throw FormatException(
      'expected ML-KEM-1024 tag 0x0A, got 0x${tag.toRadixString(16)}',
    );
  }
  if (serialized.length != 1 + MlKem1024.publicKeyLength) {
    throw FormatException(
      'ML-KEM-1024 serialize length must be '
      '${1 + MlKem1024.publicKeyLength}, got ${serialized.length}',
    );
  }
  return Uint8List.fromList(serialized.sublist(1));
}

/// True when [serialized] is a tagged ML-KEM-1024 public key.
bool isMlKem1024PublicKey(List<int> serialized) {
  return serialized.isNotEmpty &&
      serialized[0] == mlKem1024Tag &&
      serialized.length == 1 + MlKem1024.publicKeyLength;
}
