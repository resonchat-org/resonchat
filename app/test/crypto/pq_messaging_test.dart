// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// End-to-end B-track (PQ-OMEMO) messaging: two devices, real ML-KEM
// handshake, real Double Ratchet, real wire format.
//
// The point is not that "it decrypts" but that the whole chain holds:
//   PQXDH → ratchet → <wrap> → XML → ratchet → payload

import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:resonchat/crypto/omemo/message_codec.dart';
import 'package:resonchat/crypto/omemo/pq_message_layer.dart';
import 'package:resonchat/crypto/omemo/pq_session.dart';
import 'package:resonchat/crypto/pq/pqcrypto_mlkem.dart';

void main() {
  final kem = PqcryptoMlKem768();

  Future<PqDevice> device(String jid) =>
      PqDevice.generate(jid, opkCount: 5, pqOpkCount: 2, kem: kem);

  test('a first message establishes a session and round-trips', () async {
    final alice = await device('alice@example.org');
    final bob = await device('bob@example.org');

    final aliceSessions = PqSessionManager(kem: kem);
    final bobSessions = PqSessionManager(kem: kem);
    // Bob resolves Alice's identity key from the bundle she published.
    final aliceIk = await alice.ikDh.pk.getBytes();
    Future<List<int>> ikOf(String _, int _) async => aliceIk;

    final aliceLayer = PqMessageLayer(
      ownDevice: alice,
      sessions: aliceSessions,
      senderIkOf: ikOf,
      random: Random(1),
    );
    final bobLayer = PqMessageLayer(
      ownDevice: bob,
      sessions: bobSessions,
      senderIkOf: ikOf,
      random: Random(2),
    );

    const plaintext = 'Post-quantum hello';
    final outgoing = await aliceLayer.encrypt(
      plaintext: plaintext,
      recipients: [bob],
    );
    expect(outgoing, isNotNull);

    // The first message must be a KEX carrying the KEM ciphertext.
    final stanza = outgoing!.stanza;
    expect(stanza.senderDeviceId, alice.id);
    expect(stanza.keys.length, 1);
    final entry = stanza.keys.single;
    expect(entry.recipientDeviceId, bob.id);
    expect(entry.kex, isTrue, reason: 'first message must carry the handshake');
    expect(entry.pqCiphertexts, isNotEmpty);
    expect(
      base64Decode(entry.pqCiphertexts.first).length,
      1088,
      reason: 'a full ML-KEM-768 ciphertext must be on the wire',
    );

    // Round-trip through XML, as it would travel.
    final onWire = PqEncryptedMessage.fromXml(stanza.toXml());
    final recovered = await bobLayer.decrypt(
      onWire,
      senderBareJid: 'alice@example.org',
    );
    expect(recovered, plaintext);
  });

  test('subsequent messages reuse the session without a KEX', () async {
    final alice = await device('alice@example.org');
    final bob = await device('bob@example.org');
    final aliceSessions = PqSessionManager(kem: kem);
    final bobSessions = PqSessionManager(kem: kem);
    final aliceIk = await alice.ikDh.pk.getBytes();
    Future<List<int>> ikOf(String _, int _) async => aliceIk;

    final aliceLayer = PqMessageLayer(
      ownDevice: alice,
      sessions: aliceSessions,
      senderIkOf: ikOf,
      random: Random(3),
    );
    final bobLayer = PqMessageLayer(
      ownDevice: bob,
      sessions: bobSessions,
      senderIkOf: ikOf,
      random: Random(4),
    );

    for (var i = 0; i < 5; i++) {
      final out = await aliceLayer.encrypt(
        plaintext: 'message $i',
        recipients: [bob],
      );
      final entry = out!.stanza.keys.single;
      expect(
        entry.kex,
        i == 0,
        reason: 'only the first message should hand shake',
      );
      expect(
        entry.pqCiphertexts.length,
        i == 0 ? 2 : 0,
        reason: 'KEM ciphertexts travel with the handshake only',
      );
      final back = await bobLayer.decrypt(
        PqEncryptedMessage.fromXml(out.stanza.toXml()),
        senderBareJid: 'alice@example.org',
      );
      expect(back, 'message $i');
    }
  });

  test(
    'a message for a different device is rejected, not silently read',
    () async {
      final alice = await device('alice@example.org');
      final bob = await device('bob@example.org');
      final eve = await device('eve@example.org');

      final aliceSessions = PqSessionManager(kem: kem);
      final aliceIk = await alice.ikDh.pk.getBytes();
      Future<List<int>> ikOf(String _, int _) async => aliceIk;
      final aliceLayer = PqMessageLayer(
        ownDevice: alice,
        sessions: aliceSessions,
        senderIkOf: ikOf,
        random: Random(5),
      );
      final eveLayer = PqMessageLayer(
        ownDevice: eve,
        sessions: PqSessionManager(kem: kem),
        senderIkOf: (_, _) => throw UnimplementedError(),
        random: Random(6),
      );

      final out = await aliceLayer.encrypt(
        plaintext: 'for bob only',
        recipients: [bob],
      );
      expect(
        () => eveLayer.decrypt(out!.stanza, senderBareJid: 'alice@example.org'),
        throwsA(isA<PqDecryptError>()),
      );
    },
  );

  test('a tampered payload fails authentication', () async {
    final alice = await device('alice@example.org');
    final bob = await device('bob@example.org');
    final bobSessions = PqSessionManager(kem: kem);
    final aliceIk = await alice.ikDh.pk.getBytes();
    Future<List<int>> ikOf(String _, int _) async => aliceIk;

    final aliceLayer = PqMessageLayer(
      ownDevice: alice,
      sessions: PqSessionManager(kem: kem),
      senderIkOf: (_, _) async => aliceIk,
      random: Random(7),
    );
    final bobLayer = PqMessageLayer(
      ownDevice: bob,
      sessions: bobSessions,
      senderIkOf: ikOf,
      random: Random(8),
    );

    final out = await aliceLayer.encrypt(
      plaintext: 'authentic',
      recipients: [bob],
    );
    final good = PqEncryptedMessage.fromXml(out!.stanza.toXml());

    // Flip a byte in the payload.
    final payload = base64Decode(good.payload);
    payload[payload.length - 20] ^= 0x01;
    final tampered = PqEncryptedMessage(
      senderDeviceId: good.senderDeviceId,
      keys: good.keys,
      iv: good.iv,
      payload: base64Encode(payload),
    );

    expect(
      () => bobLayer.decrypt(tampered, senderBareJid: 'alice@example.org'),
      throwsA(
        isA<PqDecryptError>().having(
          (e) => e.reason,
          'reason',
          contains('authentication'),
        ),
      ),
    );

    // The untampered copy still works, so the failure above was specific.
    expect(
      await bobLayer.decrypt(good, senderBareJid: 'alice@example.org'),
      'authentic',
    );
  });

  test('fan-out: one payload, a wrap per device', () async {
    final alice = await device('alice@example.org');
    final bob = await device('bob@example.org');
    final bob2 = await device('bob@example.org/laptop');

    final aliceSessions = PqSessionManager(kem: kem);
    final aliceIk = await alice.ikDh.pk.getBytes();
    final out = await PqMessageLayer(
      ownDevice: alice,
      sessions: aliceSessions,
      senderIkOf: (_, _) async => aliceIk,
      random: Random(9),
    ).encrypt(plaintext: 'to all my devices', recipients: [bob, bob2]);

    expect(out!.stanza.keys.length, 2);
    expect(out.stanza.keys.map((k) => k.recipientDeviceId).toSet(), {
      bob.id,
      bob2.id,
    });
    // The payload is encrypted once; only the wraps multiply.
    expect(out.stanza.keys.map((k) => k.wrap).toSet().length, 2);
  });

  test('an empty recipient list refuses to produce a message', () async {
    final alice = await device('alice@example.org');
    final layer = PqMessageLayer(
      ownDevice: alice,
      sessions: PqSessionManager(kem: kem),
      senderIkOf: (_, _) => throw UnimplementedError(),
    );
    expect(
      await layer.encrypt(plaintext: 'nobody', recipients: const []),
      isNull,
    );
  });

  test('unicode and long messages survive the round-trip', () async {
    final alice = await device('alice@example.org');
    final bob = await device('bob@example.org');
    final bobSessions = PqSessionManager(kem: kem);
    final aliceIk = await alice.ikDh.pk.getBytes();
    Future<List<int>> ikOf(String _, int _) async => aliceIk;

    final layer = PqMessageLayer(
      ownDevice: alice,
      sessions: PqSessionManager(kem: kem),
      senderIkOf: (_, _) async => aliceIk,
      random: Random(10),
    );
    final bobLayer = PqMessageLayer(
      ownDevice: bob,
      sessions: bobSessions,
      senderIkOf: ikOf,
      random: Random(11),
    );

    final text = '后量子加密 🔐 ' * 200;
    final out = await layer.encrypt(plaintext: text, recipients: [bob]);
    final back = await bobLayer.decrypt(
      PqEncryptedMessage.fromXml(out!.stanza.toXml()),
      senderBareJid: 'alice@example.org',
    );
    expect(back, text);
  });
}
