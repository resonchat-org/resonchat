// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Exercises the in-app ML-KEM backend (pure-Dart pqcrypto) on device.
//
//   flutter test integration_test/native_pq_test.dart -d <device>

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:resonchat/crypto/omemo2/mlkem.dart';
import 'package:resonchat/crypto/omemo2/mlkem_provider.dart';

void main() {
  test('pqcrypto ML-KEM-768 backend is available and functional', () {
    final kem = MlKem768Provider.instance.kem;
    // ignore: avoid_print
    print('backend: pqcrypto (Dart)');
    // ignore: avoid_print
    print('platform: ${Platform.operatingSystem}/${Platform.version}');

    final kp = kem.generateKeyPair();
    expect(kp.publicKey.length, MlKem768.publicKeyLength);
    expect(kp.secretKey.length, MlKem768.secretKeyLength);

    final enc = kem.encapsulate(kp.publicKey);
    expect(enc.ciphertext.length, MlKem768.ciphertextLength);
    expect(enc.sharedSecret.length, MlKem768.sharedSecretLength);
    expect(kem.decapsulate(kp.secretKey, enc.ciphertext), enc.sharedSecret);
  });
}
