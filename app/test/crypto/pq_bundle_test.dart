// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The B-track publish path: a local PqDevice must survive being written to
// a bundle, published, and read back as something we can encrypt to.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';
import 'package:resonchat/crypto/omemo/bundle_codec.dart';
import 'package:resonchat/crypto/omemo/dual_track_manager.dart';
import 'package:resonchat/crypto/omemo/pq_session.dart';
import 'package:resonchat/crypto/pq/mlkem.dart';
import 'package:resonchat/crypto/pq/pqcrypto_mlkem.dart';

/// Serialises [device] the way the publisher does.
Future<PqBundle> toBundle(PqDevice device) async {
  final prekeys = <int, String>{};
  for (final e in device.opks.entries) {
    prekeys[e.key] = base64Encode(await e.value.pk.getBytes());
  }
  final pqPrekeys = <int, String>{};
  for (final e in device.pqOpks.entries) {
    pqPrekeys[e.key] = base64Encode(e.value.publicKey);
  }
  return PqBundle(
    deviceId: device.id,
    jid: device.jid,
    spk: base64Encode(await device.spk.pk.getBytes()),
    spkId: device.spkId,
    spkSignature: base64Encode(device.spkSignature),
    ikEncoded: base64Encode(await device.ikDh.pk.getBytes()),
    prekeys: prekeys,
    pqSpkId: device.pqSpkId,
    pqSpk: base64Encode(device.pqSpk),
    pqSpkSignature: base64Encode(device.pqSpkSignature),
    pqPrekeys: pqPrekeys,
  );
}

void main() {
  final kem = PqcryptoMlKem768();

  Future<PqDevice> device(String jid) =>
      PqDevice.generate(jid, opkCount: 3, pqOpkCount: 2, kem: kem);

  test('a bundle survives XML round-trip with every field intact', () async {
    final alice = await device('alice@example.org');
    final bundle = await toBundle(alice);

    final parsed = PqBundle.fromXml(bundle.toXml(), jidOfBundle: alice.jid);

    expect(parsed.deviceId, alice.id);
    expect(parsed.jid, alice.jid);
    expect(parsed.spkId, alice.spkId);
    expect(base64Decode(parsed.spk), await alice.spk.pk.getBytes());
    expect(base64Decode(parsed.ikEncoded), await alice.ikDh.pk.getBytes());
    expect(parsed.prekeys.keys.toSet(), alice.opks.keys.toSet());
    expect(parsed.pqPrekeys.keys.toSet(), alice.pqOpks.keys.toSet());
    expect(base64Decode(parsed.pqSpk), alice.pqSpk);
    expect(parsed.hasPqKeys, isTrue);
  });

  test('a bundle read back yields a device we can encrypt to', () async {
    final alice = await device('alice@example.org');
    final published = PqBundle.fromXml(
      (await toBundle(alice)).toXml(),
      jidOfBundle: alice.jid,
    );

    final restored = await DualTrackManager.deviceFromBundle(published);
    expect(restored, isNotNull);
    expect(restored!.id, alice.id);
    expect(restored.jid, alice.jid);
    expect(restored.spkId, alice.spkId);
    expect(await restored.spk.pk.getBytes(), await alice.spk.pk.getBytes());
    expect(await restored.ikDh.pk.getBytes(), await alice.ikDh.pk.getBytes());
    expect(restored.pqSpk.length, MlKem768.publicKeyLength);
    expect(restored.opks.length, alice.opks.length);
    expect(restored.pqOpks.length, alice.pqOpks.length);

    // A real handshake against the restored public material must work:
    // this is exactly what happens when we encrypt to a peer.
    final bob = await device('bob@example.org');
    final kex = await PqSessionManager(kem: kem)
        .initiate(own: bob, peer: restored);
    expect(kex.pqCiphertexts.length, 2);
    expect(kex.pqCiphertexts.first.length, MlKem768.ciphertextLength);
  });

  test('private key material never appears in the bundle', () async {
    final alice = await device('alice@example.org');
    final xml = (await toBundle(alice)).toXml().toXmlString();

    expect(
      xml,
      isNot(contains(base64Encode(await alice.ikDh.sk.getBytes()))),
      reason: 'identity private key leaked into the bundle',
    );
    expect(
      xml,
      isNot(contains(base64Encode(alice.pqSpkSecret))),
      reason: 'ML-KEM private key leaked into the bundle',
    );
    for (final opk in alice.opks.values) {
      expect(
        xml,
        isNot(contains(base64Encode(await opk.sk.getBytes()))),
        reason: 'one-time prekey private half leaked',
      );
    }
  });

  test('a bundle missing its PQ section reports hasPqKeys false', () {
    final stripped = PqBundle.fromXml(
      XmlDocument.parse(
        '<bundle xmlns="urn:xmpp:pomemo:0" device="1">'
        '<spk id="3">AAAA</spk><spsk>AAAA</spsk><ik>AAAA</ik>'
        '</bundle>',
      ).rootElement,
      jidOfBundle: 'x@y',
    );
    expect(stripped.hasPqKeys, isFalse);
    expect(stripped.spkId, 3);
  });

  test('deviceFromBundle refuses malformed key material', () async {
    final bad = PqBundle(
      deviceId: 1,
      jid: 'x@y',
      spk: base64Encode(List<int>.filled(31, 1)), // wrong length
      spkId: 1,
      spkSignature: base64Encode(List<int>.filled(64, 2)),
      ikEncoded: base64Encode(List<int>.filled(32, 3)),
      prekeys: const {},
      pqSpkId: 1,
      pqSpk: base64Encode(List<int>.filled(1184, 4)),
      pqSpkSignature: base64Encode(List<int>.filled(64, 5)),
      pqPrekeys: const {},
    );
    expect(await DualTrackManager.deviceFromBundle(bad), isNull);
  });

  test(
    'a restored device cannot be used to decrypt (no private half)',
    () async {
      final alice = await device('alice@example.org');
      final restored = await DualTrackManager.deviceFromBundle(
        PqBundle.fromXml(
          (await toBundle(alice)).toXml(),
          jidOfBundle: alice.jid,
        ),
      );
      expect(restored, isNotNull);
      // Private material is intentionally zero-filled: it must not match the
      // real device, so nobody can be fooled into treating it as a local key.
      expect(
        await restored!.ikDh.sk.getBytes(),
        isNot(await alice.ikDh.sk.getBytes()),
      );
      expect(restored.pqSpkSecret, isEmpty);
    },
  );
}
