// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// PQXDH lives in native libsignal; this file covers KEM sizes + label constant.

import 'package:test/test.dart';
import 'package:resonchat/crypto/fingerprint.dart';
import 'package:resonchat/crypto/pqxdh.dart';
import 'package:resonchat/crypto/pq/pqcrypto_mlkem.dart';

void main() {
  group('ML-KEM-1024', () {
    final kem = PqcryptoMlKem1024();

    test('sizes match FIPS 203 for ML-KEM-1024', () {
      final kp = kem.generateKeyPair();
      expect(kp.publicKey.length, 1568);
      expect(kp.secretKey.length, 3168);
      final enc = kem.encapsulate(kp.publicKey);
      expect(enc.ciphertext.length, 1568);
      expect(enc.sharedSecret.length, 32);
    });

    test('encapsulate/decapsulate agree on the shared secret', () {
      final bob = kem.generateKeyPair();
      final enc = kem.encapsulate(bob.publicKey);
      final dec = kem.decapsulate(bob.secretKey, enc.ciphertext);
      expect(dec, enc.sharedSecret);
    });
  });

  group('PQXDH label', () {
    test('matches libsignal WhisperText schedule name', () {
      expect(
        omemo2PqxdhHkdfLabel,
        'WhisperText_X25519_SHA-256_CRYSTALS-KYBER-1024',
      );
    });
  });

  group('fingerprint', () {
    test('SHA-256 hex is 64 chars and stable', () async {
      final fp = await sha256Hex([1, 2, 3]);
      expect(fp.length, 64);
      expect(fp, await sha256Hex([1, 2, 3]));
    });

    test('formatFingerprint groups classical serialize hex', () {
      final classical =
          '05${List.filled(32, 'ab').join()}'; // 1+32 bytes → 66 hex
      final pretty = formatFingerprint(classical);
      expect(pretty.startsWith('abababab'), isTrue);
      expect(pretty.contains(' '), isTrue);
    });
  });
}
