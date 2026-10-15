// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';

import 'package:pqcrypto/pqcrypto.dart';

import 'mlkem.dart';

/// Pure-Dart ML-KEM-1024 via `package:pqcrypto` (FIPS 203) — monocles OMEMO2.
class PqcryptoMlKem1024 implements MlKem1024 {
  PqcryptoMlKem1024() : _kem = PqcKem.kyber1024;

  final KyberKem _kem;

  @override
  KemKeyPair generateKeyPair() {
    final (pk, sk) = _kem.generateKeyPair();
    return KemKeyPair(publicKey: pk, secretKey: sk);
  }

  @override
  KemEncapsulation encapsulate(List<int> publicKey) {
    final (ct, ss) = _kem.encapsulate(Uint8List.fromList(publicKey));
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

/// Pure-Dart ML-KEM-768 via `package:pqcrypto` (retained for tests).
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
    final (ct, ss) = _kem.encapsulate(Uint8List.fromList(publicKey));
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
