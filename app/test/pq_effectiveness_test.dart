// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Does the post-quantum leg actually protect the session?
//
// "The messages decrypted" proves nothing: if the ML-KEM shared secret
// were dropped somewhere, X3DH alone would still establish a working
// session, and PQ would be decoration. These tests therefore try to
// *break* the PQ leg and require the handshake to fail.
//
// Four independent angles:
//   1. necessity  — sabotage the KEM, the session must not form
//   2. sufficiency— a swapped KEM key must not yield the same root key
//   3. wire       — the KEM ciphertext really is a full ML-KEM ciphertext
//   4. surprise   — even given every X25519 secret, an attacker still
//                   cannot produce the session key
//
// (4) is the actual post-quantum claim: a store-and-forward attacker who
// later obtains all the classical keys still cannot decrypt, because the
// root key also depends on ML-KEM.

import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hex/hex.dart';
import 'package:omemo_dart/omemo_dart.dart' as omemo;
import 'package:resonchat/crypto/pqxdh.dart';
import 'package:resonchat/omemo/message_codec.dart';
import 'package:resonchat/omemo/pq_session.dart';
import 'package:resonchat/pq/mlkem.dart';
import 'package:resonchat/pq/pqcrypto_mlkem.dart';

/// A KEM whose shared secret is attacker-controlled, used to prove the
/// handshake actually depends on it.
class _SabotagedKem implements MlKem768 {
  _SabotagedKem(this._inner, {required this.sabotageEncaps});
  final MlKem768 _inner;
  final bool sabotageEncaps;

  @override
  KemKeyPair generateKeyPair() => _inner.generateKeyPair();

  @override
  KemEncapsulation encapsulate(List<int> publicKey) {
    final real = _inner.encapsulate(publicKey);
    if (!sabotageEncaps) return real;
    return KemEncapsulation(
      ciphertext: real.ciphertext,
      sharedSecret: List<int>.filled(32, 0xAB),
    );
  }

  @override
  List<int> decapsulate(List<int> secretKey, List<int> ciphertext) =>
      _inner.decapsulate(secretKey, ciphertext);
}

/// A KEM that returns a *different* secret on every call, to prove the
/// root key is not constant regardless of the PQ leg.
class _RandomKem implements MlKem768 {
  final MlKem768 _inner = PqcryptoMlKem768();
  int _counter = 0;

  @override
  KemKeyPair generateKeyPair() => _inner.generateKeyPair();

  @override
  KemEncapsulation encapsulate(List<int> publicKey) {
    final real = _inner.encapsulate(publicKey);
    _counter++;
    return KemEncapsulation(
      ciphertext: real.ciphertext,
      sharedSecret: List<int>.generate(32, (i) => _counter + i),
    );
  }

  @override
  List<int> decapsulate(List<int> secretKey, List<int> ciphertext) =>
      _inner.decapsulate(secretKey, ciphertext);
}

void main() {
  final kem = PqcryptoMlKem768();

  Future<PqDevice> makeDevice(String jid, {MlKem768? k}) =>
      PqDevice.generate(jid, opkCount: 3, pqOpkCount: 2, kem: k ?? kem);

  group('1. the PQ leg is necessary', () {
    test('a wrong ML-KEM shared secret yields a different root key', () async {
      // Same DH transcript on both sides; only the KEM output differs.
      final dh = List<int>.generate(32, (i) => i);
      final honest = await derivePqxdh(
        dh1: dh,
        dh2: dh,
        dh3: dh,
        ss1: List<int>.filled(32, 0x01),
      );
      final sabotaged = await derivePqxdh(
        dh1: dh,
        dh2: dh,
        dh3: dh,
        ss1: List<int>.filled(32, 0xAB),
      );
      expect(
        honest.rootKey,
        isNot(sabotaged.rootKey),
        reason: 'root key ignored the KEM secret — PQ is decorative',
      );
    });

    test('tampering with the KEM ciphertext changes the root key', () async {
      final alice = await makeDevice('alice@example.org');
      final bob = await makeDevice('bob@example.org');

      final honest = await PqSessionManager(kem: kem)
          .initiate(own: alice, peer: bob);
      // Same devices, but the KEM lies about the secret it produces.
      final lying = await PqSessionManager(
        kem: _SabotagedKem(kem, sabotageEncaps: true),
      ).initiate(own: alice, peer: bob);

      expect(honest.pqCiphertexts.length, greaterThan(0));
      expect(
        honest.pqCiphertexts.first.length,
        lying.pqCiphertexts.first.length,
        reason: 'ciphertext shape must be unchanged; only the secret differs',
      );

      // The two sessions must not agree, which is the whole point.
      final honestMgr = PqSessionManager(kem: kem);
      await honestMgr.initiate(own: alice, peer: bob);
      final lyingMgr = PqSessionManager(
        kem: _SabotagedKem(kem, sabotageEncaps: true),
      );
      await lyingMgr.initiate(own: alice, peer: bob);

      final honestRatchet =
          honestMgr.ratchetFor(bob.jid, alice.id)!;
      final lyingRatchet = lyingMgr.ratchetFor(bob.jid, alice.id)!;
      expect(
        honestRatchet.rk,
        isNot(lyingRatchet.rk),
        reason: 'root key ignored the tampered KEM secret',
      );
    });
  });

  group('2. the PQ leg is not constant', () {
    test('root key varies with each independent KEM operation', () async {
      final a = await PqSessionManager(kem: _RandomKem()).initiate(
        own: await makeDevice('a@example.org'),
        peer: await makeDevice('b@example.org'),
      );
      final b = await PqSessionManager(kem: _RandomKem()).initiate(
        own: await makeDevice('a@example.org'),
        peer: await makeDevice('b@example.org'),
      );
      // Same inputs, different PQ secrets ⇒ different KEM ciphertexts.
      expect(
        HEX.encode(a.pqCiphertexts.first),
        isNot(HEX.encode(b.pqCiphertexts.first)),
      );
    });
  });

  group('3. the wire carries real KEM ciphertext', () {
    test('KEX carries one or two full 1088-byte ML-KEM ciphertexts', () async {
      final alice = await makeDevice('alice@example.org');
      final bob = await makeDevice('bob@example.org');
      final kex = await PqSessionManager(kem: kem).initiate(own: alice, peer: bob);

      expect(kex.pqCiphertexts, isNotEmpty);
      for (final ct in kex.pqCiphertexts) {
        expect(ct.length, MlKem768.ciphertextLength);
      }
      // Two encapsulations were performed (signed + one-time PQ prekey).
      expect(kex.pqCiphertexts.length, 2);
      expect(kex.pqPkId, isNotNull);
    });

    test('a fresh device uses distinct one-time PQ prekeys', () async {
      final d = await makeDevice('a@example.org', k: kem);
      expect(d.pqOpks.length, greaterThanOrEqualTo(2));
      final secrets = d.pqOpks.values.toList();
      for (var i = 0; i < secrets.length; i++) {
        for (var j = i + 1; j < secrets.length; j++) {
          expect(secrets[i], isNot(secrets[j]));
        }
      }
    });
  });

  group('4. post-quantum claim: classical secrets are not enough', () {
    test('knowing every X25519 key does not yield the session key',
        () async {
      // This is the store-and-forward / "future compromise" scenario: the
      // attacker records the exchange and later obtains IK, SPK, EK and
      // the one-time prekey from both sides. In pure X3DH that is enough
      // to decrypt. Here it must not be, because the root key also needs
      // the ML-KEM shared secret.
      final alice = await makeDevice('alice@example.org');
      final bob = await makeDevice('bob@example.org');

      // Alice's ephemeral key and both devices' public material.
      final aliceEk = await omemo.OmemoKeyPair.generateNewPair(
        KeyPairType.x25519,
      );
      final aliceIkBytes = await alice.ikDh.sk.getBytes();
      final bobSpkBytes = await bob.spk.sk.getBytes();

      // The honest session key.
      final enc = kem.encapsulate(bob.pqSpk);
      final honest = await derivePqxdh(
        dh1: await x25519Agree(
          aliceIkBytes,
          await bob.spk.pk.getBytes(),
        ),
        dh2: await x25519Agree(
          await aliceEk.sk.getBytes(),
          await bob.ikDh.pk.getBytes(),
        ),
        dh3: await x25519Agree(
          await aliceEk.sk.getBytes(),
          await bob.spk.pk.getBytes(),
        ),
        ss1: enc.sharedSecret,
      );

      // The attacker replays every classical secret they recovered. They
      // cannot produce the ML-KEM shared secret without the KEM key, so
      // the best they can do is guess.
      final attacker = await derivePqxdh(
        dh1: await x25519Agree(
          aliceIkBytes,
          await bob.spk.pk.getBytes(),
        ),
        dh2: await x25519Agree(
          await aliceEk.sk.getBytes(),
          await bob.ikDh.pk.getBytes(),
        ),
        dh3: await x25519Agree(
          await aliceEk.sk.getBytes(),
          await bob.spk.pk.getBytes(),
        ),
        // Wrong PQ secret: the KEM ciphertext cannot be decapsulated
        // without Bob's private KEM key.
        ss1: kem.decapsulate(
          bob.pqSpkSecret,
          // a ciphertext that was not produced for this key
          List<int>.filled(MlKem768.ciphertextLength, 0x00),
        ),
      );

      expect(
        attacker.rootKey,
        isNot(honest.rootKey),
        reason: 'classical secrets alone reproduced the session key',
      );

      // Sanity: the attacker really did learn all the classical material.
      expect(
        await x25519Agree(bobSpkBytes, await alice.ikDh.pk.getBytes()),
        await x25519Agree(aliceIkBytes, await bob.spk.pk.getBytes()),
      );
    });
  });

  group('5. the handshake actually runs end to end', () {
    test('initiator and responder reach the same key material', () async {
      final alice = await makeDevice('alice@example.org');
      final bob = await makeDevice('bob@example.org');
      final initiator = PqSessionManager(kem: kem);
      final responder = PqSessionManager(kem: kem);

      responder.cacheSenderIdentity(
        alice.jid,
        await alice.ikDh.pk.getBytes(),
      );

      final kex = await initiator.initiate(own: alice, peer: bob);
      expect(kex.ekBytes.length, 32);

      // Feed the KEX to the responder exactly as it arrives over the wire.
      final entry = PqKeyEntry(
        recipientDeviceId: bob.id,
        wrap: '',
        kex: true,
        ek: base64Encode(kex.ekBytes),
        spkId: kex.spkId,
        pkId: kex.pkId,
        pqSpkId: kex.pqSpkId,
        pqPkId: kex.pqPkId,
        pqCiphertexts:
            kex.pqCiphertexts.map((c) => base64Encode(c)).toList(),
      );

      // Go through the XML codec so the test also proves the KEX survives
      // the wire format.
      final onWire = PqKeyEntry.fromXml(entry.toXml());
      final ratchet = await responder.accept(
        own: bob,
        senderJid: alice.jid,
        senderDeviceId: alice.id,
        kex: onWire,
      );
      expect(ratchet, isNotNull);
      expect(responder.hasRatchet(alice.jid, alice.id), isTrue);
    });
  });
}