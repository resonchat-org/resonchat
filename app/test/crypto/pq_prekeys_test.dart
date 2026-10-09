// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The ML-KEM one-time prekey pool must not run dry: each new inbound
// B-track session consumes one, and once empty every later handshake falls
// back to the signed PQ prekey (weaker forward secrecy).

import 'package:flutter_test/flutter_test.dart';
import 'package:resonchat/crypto/omemo/pq_session.dart';
import 'package:resonchat/crypto/pq/mlkem.dart';
import 'package:resonchat/crypto/pq/pqcrypto_mlkem.dart';

void main() {
  final kem = PqcryptoMlKem768();

  test('a generated device has the requested PQ pool', () async {
    final device = await PqDevice.generate(
      'me@example.org',
      opkCount: 3,
      pqOpkCount: 4,
      kem: kem,
    );
    expect(device.pqOpks.length, 4);
  });

  test('every PQ one-time prekey is distinct and correctly sized', () async {
    final device = await PqDevice.generate(
      'me@example.org',
      opkCount: 2,
      pqOpkCount: 5,
      kem: kem,
    );
    final secrets = device.pqOpks.values.map((e) => e.secretKey).toList();
    final publics = device.pqOpks.values.map((e) => e.publicKey).toList();

    for (final s in secrets) {
      expect(s.length, MlKem768.secretKeyLength);
    }
    for (final p in publics) {
      expect(p.length, MlKem768.publicKeyLength);
    }
    // Two identical prekeys would let one capture be replayed twice.
    expect(secrets.toSet().length, secrets.length);
    expect(publics.toSet().length, publics.length);
  });

  test('a pool entry can actually be used for a handshake', () async {
    final alice = await PqDevice.generate(
      'alice@example.org',
      opkCount: 3,
      pqOpkCount: 3,
      kem: kem,
    );
    final bob = await PqDevice.generate(
      'bob@example.org',
      opkCount: 3,
      pqOpkCount: 3,
      kem: kem,
    );

    final kex = await PqSessionManager(kem: kem)
        .initiate(own: alice, peer: bob);
    expect(kex.pqPkId, isNotNull, reason: 'should use a PQ one-time prekey');
    expect(kex.pqCiphertexts.length, 2, reason: 'signed prekey + one-time');
    for (final ct in kex.pqCiphertexts) {
      expect(ct.length, MlKem768.ciphertextLength);
    }

    // The responder must be able to decapsulate with the matching entry.
    final ss2 = kem.decapsulate(
      bob.pqOpks[kex.pqPkId]!.secretKey,
      kex.pqCiphertexts[1],
    );
    expect(ss2.length, MlKem768.sharedSecretLength);
  });

  test('exhausting the pool still works via the signed prekey', () async {
    // Degraded but functional: PQ is retained (signed prekey is also
    // ML-KEM), only the extra forward secrecy of one-time keys is lost.
    final alice = await PqDevice.generate(
      'alice@example.org',
      opkCount: 3,
      pqOpkCount: 0,
      kem: kem,
    );
    final bob = await PqDevice.generate(
      'bob@example.org',
      opkCount: 3,
      pqOpkCount: 0,
      kem: kem,
    );
    final kex = await PqSessionManager(kem: kem)
        .initiate(own: alice, peer: bob);
    expect(kex.pqPkId, isNull);
    expect(kex.pqCiphertexts.length, 1, reason: 'signed PQ prekey only');
    expect(kex.pqCiphertexts.single.length, MlKem768.ciphertextLength);
  });
}
