// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';

import 'package:pqcrypto/pqcrypto.dart';

import 'mlkem.dart';

/// Pure-Dart ML-KEM-768 via `package:pqcrypto` (FIPS 203).
///
/// Fast enough for session establishment (a few ms on mobile); runs on
/// every platform with no native toolchain. See docs/04-crypto-android.md.
class PqcryptoMlKem768 implements MlKem768 {
  PqcryptoMlKem768() : _kem = PqcKem.kyber768;

  final KyberKem _kem;

  @override
  KemKeyPair generateKeyPair() {
    final (pk, sk) = _kem.generateKeyPair();
    return KemKeyPair(publicKey: pk, secretKey: sk);
  }

  @override
  KemEncapsulation encapsulate(List<int> publicKey) {
    final (ct, ss) =
        _kem.encapsulate(Uint8List.fromList(publicKey));
    return KemEncapsulation(ciphertext: ct, sharedSecret: ss);
  }

  @override
  List<int> decapsulate(List<int> secretKey, List<int> ciphertext) {
    return _kem.decapsulate(
      Uint8List.fromList(secretKey),
      Uint8List.fromList(ciphertext),
    );
  }
}
