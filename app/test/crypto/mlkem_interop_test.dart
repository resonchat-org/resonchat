// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// ML-KEM-768 contract checks for the pure-Dart `pqcrypto` backend
// (ADR-006, docs/04 §3): FIPS 203 sizes, implicit rejection, and a
// derandomised reproducibility path our PQ helpers rely on.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pqcrypto/pqcrypto.dart';

import 'package:resonchat/crypto/omemo2/mlkem.dart';
import 'package:resonchat/crypto/omemo2/pqcrypto_mlkem.dart';

final _keySeed = List<int>.generate(64, (i) => i);
final _encSeed = List<int>.generate(32, (i) => 0xFF - i);

void main() {
  group('FIPS 203 contract', () {
    test('pure-Dart backend produces ML-KEM-768 sized values', () {
      final kem = PqcryptoMlKem768();
      final kp = kem.generateKeyPair();
      expect(kp.publicKey.length, MlKem768.publicKeyLength);
      expect(kp.secretKey.length, MlKem768.secretKeyLength);

      final enc = kem.encapsulate(kp.publicKey);
      expect(enc.ciphertext.length, MlKem768.ciphertextLength);
      expect(enc.sharedSecret.length, MlKem768.sharedSecretLength);
    });

    test('decapsulating with the wrong key yields a different secret', () {
      final kem = PqcryptoMlKem768();
      final bob = kem.generateKeyPair();
      final eve = kem.generateKeyPair();
      final enc = kem.encapsulate(bob.publicKey);
      expect(
        kem.decapsulate(eve.secretKey, enc.ciphertext),
        isNot(enc.sharedSecret),
      );
    });

    test('a tampered ciphertext never returns the original secret', () {
      // ML-KEM uses implicit rejection: no error is thrown, the caller
      // gets a pseudo-random secret. Our code must therefore never treat
      // "decapsulation succeeded" as proof of authenticity.
      final kem = PqcryptoMlKem768();
      final bob = kem.generateKeyPair();
      final enc = kem.encapsulate(bob.publicKey);
      final tampered = List<int>.from(enc.ciphertext);
      tampered[0] ^= 0xFF;
      expect(kem.decapsulate(bob.secretKey, tampered), isNot(enc.sharedSecret));
    });
  });

  group('pqcrypto deterministic path', () {
    test('derandomised keygen and encaps are reproducible', () {
      final kem = PqcKem.kyber768;

      final a = kem.generateKeyPair(Uint8List.fromList(_keySeed));
      final b = kem.generateKeyPair(Uint8List.fromList(_keySeed));
      expect(a.$1, b.$1, reason: 'seeded keygen must be deterministic');
      expect(a.$2, b.$2);

      final e1 = kem.encapsulate(
        Uint8List.fromList(a.$1),
        Uint8List.fromList(_encSeed),
      );
      final e2 = kem.encapsulate(
        Uint8List.fromList(a.$1),
        Uint8List.fromList(_encSeed),
      );
      expect(e1.$1, e2.$1, reason: 'seeded encaps must be deterministic');
      expect(e1.$2, e2.$2);
    });
  });
}
