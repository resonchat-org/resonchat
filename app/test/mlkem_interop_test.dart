// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Cross-implementation check for ML-KEM-768 (ADR-006, docs/04 §3).
//
// The pure-Dart `pqcrypto` backend and the liboqs backend must produce
// identical keys and shared secrets for identical inputs. Because both
// backends deliberately randomise normal operation, this compares the
// *deterministic* (derandomised) paths: the C reference binary built by
// tool/build_liboqs.sh emits KAT values from fixed seeds, and we check the
// Dart backend reproduces them byte-for-byte.
//
// Also asserts the FIPS 203 size contract and implicit-rejection
// behaviour, which are the properties our PQXDH code relies on.
//
// The native comparison is skipped, not failed, when the helper has not
// been built, so the suite stays green on machines without an NDK.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hex/hex.dart';
import 'package:pqcrypto/pqcrypto.dart';
import 'package:resonchat/pq/mlkem.dart';
import 'package:resonchat/pq/pqcrypto_mlkem.dart';

/// Written by tool/build_liboqs.sh.
const _refHelper = 'build/liboqs-ref/mlkem_ref';

/// Seeds used by tool/native/mlkem_ref.c.
final _keySeed = List<int>.generate(64, (i) => i);
final _encSeed = List<int>.generate(32, (i) => 0xFF - i);

Map<String, String> _parseRef(String raw) => {
      for (final line in raw.split('\n'))
        if (line.contains('='))
          line.split(':')[0].split('=')[0].trim(): line.split('=')[1].trim(),
    };

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
      expect(
        kem.decapsulate(bob.secretKey, tampered),
        isNot(enc.sharedSecret),
      );
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

  group('liboqs agreement', () {
    final helper = File(_refHelper);
    final available = helper.existsSync();

    test(
      'Dart backend reproduces liboqs deterministic KAT values',
      () {
        final proc = Process.runSync(_refHelper, const []);
        expect(proc.exitCode, 0, reason: '${proc.stderr}');
        final ref = _parseRef('${proc.stdout}');

        expect(ref['roundtrip'], '1',
            reason: 'liboqs encaps/decaps disagreed with itself');

        final kem = PqcKem.kyber768;
        final (pk, sk) = kem.generateKeyPair(Uint8List.fromList(_keySeed));
        final (ct, ss) = kem.encapsulate(
          Uint8List.fromList(pk),
          Uint8List.fromList(_encSeed),
        );
        final back = kem.decapsulate(Uint8List.fromList(sk), Uint8List.fromList(ct));

        expect(HEX.encode(pk), ref['pk'],
            reason: 'public keys differ from liboqs');
        expect(HEX.encode(sk), ref['sk'],
            reason: 'secret keys differ from liboqs');
        expect(HEX.encode(ct), ref['ct'],
            reason: 'ciphertexts differ from liboqs');
        expect(HEX.encode(ss), ref['ss'],
            reason: 'shared secrets differ from liboqs');
        expect(HEX.encode(back), ref['ss'],
            reason: 'Dart decapsulation differs from liboqs');
      },
      skip: available ? false : 'liboqs reference helper not built',
    );
  });
}