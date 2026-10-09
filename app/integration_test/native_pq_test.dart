// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Prints which ML-KEM-768 backend is active and exercises it.
//
// Run on a device to confirm the native liboqs bridge actually loaded
// (rather than silently falling back to pure Dart):
//
//   flutter test integration_test/native_pq_test.dart -d <device>

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:resonchat/pq/liboqs_mlkem.dart';
import 'package:resonchat/pq/mlkem.dart';

void main() {
  test('native or Dart backend is available and functional', () {
    final provider = MlKem768Provider.instance;
    final kem = provider.kem;
    // ignore: avoid_print
    print(
      'backend: ${provider.isNative ? 'liboqs (native)' : 'pqcrypto (Dart)'}',
    );
    // ignore: avoid_print
    print('loadError: ${liboqsLoadError ?? 'none'}');
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
