// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// PQXDH handshake tests (docs/02 §3). These cover the invariants the
// whole B track rests on: KEM agreement, DH transcript symmetry, and
// the fact that the PQ shared secret actually enters the root key.

import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:test/test.dart';
import 'package:resonchat/crypto/fingerprint.dart';
import 'package:resonchat/crypto/pqxdh.dart';
import 'package:resonchat/pq/pqcrypto_mlkem.dart';

void main() {
  group('ML-KEM-768', () {
    final kem = PqcryptoMlKem768();

    test('sizes match FIPS 203 for ML-KEM-768', () {
      final kp = kem.generateKeyPair();
      expect(kp.publicKey.length, 1184);
      expect(kp.secretKey.length, 2400);
      final enc = kem.encapsulate(kp.publicKey);
      expect(enc.ciphertext.length, 1088);
      expect(enc.sharedSecret.length, 32);
    });

    test('encapsulate/decapsulate agree on the shared secret', () {
      final bob = kem.generateKeyPair();
      final enc = kem.encapsulate(bob.publicKey);
      final dec = kem.decapsulate(bob.secretKey, enc.ciphertext);
      expect(dec, enc.sharedSecret);
    });

    test('a different keypair cannot decapsulate to the same secret', () {
      final bob = kem.generateKeyPair();
      final eve = kem.generateKeyPair();
      final enc = kem.encapsulate(bob.publicKey);
      final dec = kem.decapsulate(eve.secretKey, enc.ciphertext);
      expect(dec, isNot(enc.sharedSecret));
    });

    test(
      'invalid ciphertext yields a distinct secret (implicit rejection)',
      () {
        final bob = kem.generateKeyPair();
        final enc = kem.encapsulate(bob.publicKey);
        final tampered = Uint8List.fromList(enc.ciphertext);
        tampered[0] ^= 0xFF;
        final dec = kem.decapsulate(bob.secretKey, tampered);
        expect(dec.length, 32);
        expect(dec, isNot(enc.sharedSecret));
      },
    );
  });

  group('PQXDH', () {
    /// Deterministic 32-byte fillers so tests compare exactly.
    Uint8List fill(int n, int seed) =>
        Uint8List.fromList(List<int>.generate(n, (i) => (i + seed) & 0xFF));

    test('both sides derive identical (rootKey, chainKey)', () async {
      final aliceIk = await X25519().newKeyPair();
      final bobIk = await X25519().newKeyPair();
      final ek = await X25519().newKeyPair();
      final spk = await X25519().newKeyPair();
      final opk = await X25519().newKeyPair();
      final pq = PqcryptoMlKem768();
      final pqSpk = pq.generateKeyPair();
      final pqOpk = pq.generateKeyPair();

      // Private scalars and public keys as raw bytes.
      Future<List<int>> priv(SimpleKeyPair kp) async =>
          (await kp.extract()).bytes;
      Future<List<int>> pub(SimpleKeyPair kp) async =>
          (await kp.extractPublicKey()).bytes;

      // --- Alice (initiator) ---
      final enc = pq.encapsulate(pqSpk.publicKey);
      final enc2 = pq.encapsulate(pqOpk.publicKey);
      final alice = await derivePqxdh(
        dh1: await x25519Agree(await priv(aliceIk), await pub(spk)),
        dh2: await x25519Agree(await priv(ek), await pub(bobIk)),
        dh3: await x25519Agree(await priv(ek), await pub(spk)),
        dh4: await x25519Agree(await priv(ek), await pub(opk)),
        ss1: enc.sharedSecret,
        ss2: enc2.sharedSecret,
      );

      // --- Bob (responder) ---
      final bob = await derivePqxdh(
        dh1: await x25519Agree(await priv(spk), await pub(aliceIk)),
        dh2: await x25519Agree(await priv(bobIk), await pub(ek)),
        dh3: await x25519Agree(await priv(spk), await pub(ek)),
        dh4: await x25519Agree(await priv(opk), await pub(ek)),
        ss1: pq.decapsulate(pqSpk.secretKey, enc.ciphertext),
        ss2: pq.decapsulate(pqOpk.secretKey, enc2.ciphertext),
      );

      expect(bob.rootKey, alice.rootKey);
      expect(bob.chainKey, alice.chainKey);
      expect(alice.rootKey.length, 32);
      expect(alice.chainKey.length, 32);
    });

    test('root key changes when the PQ shared secret changes', () async {
      final dh = fill(32, 7);
      final withPq1 = await derivePqxdh(
        dh1: dh,
        dh2: dh,
        dh3: dh,
        ss1: fill(32, 1),
      );
      final withPq2 = await derivePqxdh(
        dh1: dh,
        dh2: dh,
        dh3: dh,
        ss1: fill(32, 2),
      );
      // Invariant 2 (docs/01 §7): the ML-KEM secret is inside the root key.
      expect(withPq1.rootKey, isNot(withPq2.rootKey));
    });

    test('root key changes when only the PQ ciphertexts differ', () async {
      final dh = fill(32, 3);
      final a = await derivePqxdh(
        dh1: dh,
        dh2: dh,
        dh3: dh,
        ss1: fill(32, 9),
        ss2: fill(32, 8),
      );
      final b = await derivePqxdh(
        dh1: dh,
        dh2: dh,
        dh3: dh,
        ss1: fill(32, 8),
        ss2: fill(32, 9),
      );
      expect(a.rootKey, isNot(b.rootKey));
    });

    test('optional DH4/ss2 change the transcript length', () async {
      final base = await derivePqxdh(
        dh1: fill(32, 1),
        dh2: fill(32, 2),
        dh3: fill(32, 3),
        ss1: fill(32, 4),
      );
      final withOpk = await derivePqxdh(
        dh1: fill(32, 1),
        dh2: fill(32, 2),
        dh3: fill(32, 3),
        dh4: fill(32, 5),
        ss1: fill(32, 4),
        ss2: fill(32, 6),
      );
      expect(withOpk.rootKey, isNot(base.rootKey));
    });
  });

  group('fingerprint', () {
    test('SHA-256 hex is 64 chars and stable', () async {
      final fp = await sha256Hex([1, 2, 3]);
      expect(fp.length, 64);
      expect(fp, await sha256Hex([1, 2, 3]));
      expect(fp, isNot(await sha256Hex([1, 2, 4])));
    });

    test('groups into 8-char blocks for on-screen comparison', () {
      const hex =
          '0123456789abcdef0123456789abcdef'
          '0123456789abcdef0123456789abcdef';
      expect(
        formatFingerprint(hex),
        '01234567 89abcdef 01234567 89abcdef '
        '01234567 89abcdef 01234567 89abcdef',
      );
    });

    test('strips whitespace and lowercases', () {
      expect(formatFingerprint('AB CD'), 'abcd');
    });
  });
}
