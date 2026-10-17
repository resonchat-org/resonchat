// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// App-path PQ round-trip: publish-shaped XML → fromXml(PEP item id) →
// deviceFromBundle → PqMessageLayer encrypt/decrypt.
//
// Mirrors monocles generateOmemo2Chat (OMEMO2 ciphertext only).

import 'dart:convert';
import 'dart:typed_data';

import 'package:libsignal/libsignal.dart';
import 'package:omemo_dart/omemo_dart_omemo2.dart'
    hide serializeMlKem1024PublicKey;
import 'package:test/test.dart';
import 'package:xml/xml.dart';
import 'package:resonchat/crypto/omemo/bundle_codec.dart';
import 'package:resonchat/crypto/omemo/dual_track_manager.dart';
import 'package:resonchat/crypto/omemo/message_codec.dart';
import 'package:resonchat/crypto/omemo/pq_message_layer.dart';
import 'package:resonchat/crypto/omemo/pq_session.dart';
import 'package:resonchat/crypto/pq/kem_wire.dart';
import 'package:resonchat/crypto/pq/mlkem_provider.dart';

Future<Omemo2Bundle> _publishShaped(Omemo2Device device) async {
  await device.ensureStores();
  final ikSerialized = await device.identityPublicSerialized();
  final ikRaw = ikSerialized.sublist(1);
  final spkRaw = await device.spk.pk.getBytes();
  final prekeys = <int, String>{};
  for (final e in device.opks.entries) {
    prekeys[e.key] = base64Encode(await e.value.pk.getBytes());
  }
  final kemSpkTagged = serializeMlKem1024PublicKey(device.pqSpk);
  final kemPrekeys = <int, String>{};
  final kemSigs = <int, String>{};
  final oneTime = <KemOneTimeKey>[];
  for (final e in device.pqOpks.entries) {
    final tagged = serializeMlKem1024PublicKey(e.value.publicRaw);
    kemPrekeys[e.key] = base64Encode(tagged);
    kemSigs[e.key] = base64Encode(e.value.signature);
    oneTime.add(KemOneTimeKey(id: e.key, publicKey: tagged));
  }
  final binding = pqKemBinding(
    kemSignedPreKeyId: device.pqSpkId,
    kemSignedPreKeyPublic: kemSpkTagged,
    oneTime: oneTime,
  );
  final pq = PqIdentityKeyPair.generate();
  final pqIk = pq.publicKey().serialize();
  final spkSerialized = Uint8List.fromList([0x05, ...spkRaw]);
  final transcript = pqBundleTranscript(
    identityKey: ikSerialized,
    pqIdentityKey: pqIk,
    signedPreKeyId: device.spkId,
    signedPreKeyPublic: spkSerialized,
    kemBinding: binding,
  );
  final pqSig = pq.sign(message: transcript).serialize();
  final ikSig = await device.sign(transcript);
  return Omemo2Bundle(
    deviceId: device.id,
    jid: device.jid,
    spk: base64Encode(spkRaw),
    spkId: device.spkId,
    spkSignature: base64Encode(device.spkSignature),
    ik: base64Encode(ikRaw),
    prekeys: prekeys,
    kemSpkId: device.pqSpkId,
    kemSpk: base64Encode(kemSpkTagged),
    kemSpkSignature: base64Encode(device.pqSpkSignature),
    kemPrekeys: kemPrekeys,
    kemPrekeySignatures: kemSigs,
    pqIk: base64Encode(pqIk),
    pqSig: base64Encode(pqSig),
    ikSig: base64Encode(ikSig),
  );
}

/// Historical publishes omitted `device=` on the payload; PEP item id remains.
XmlElement _stripDeviceAttr(XmlElement el) {
  final xml = el.toXmlString().replaceFirst(RegExp(r'\sdevice="\d+"'), '');
  return XmlDocument.parse(xml).rootElement;
}

void main() {
  setUpAll(() async {
    await omemo2EnsureLibSignal();
  });

  test('PEP item id + publish XML → encrypt → decrypt', () async {
    final alice = await Omemo2Device.generate(
      'alice@example.org',
      opkCount: 2,
      pqOpkCount: 1,
      deviceId: 111,
    );
    final bob = await Omemo2Device.generate(
      'bob@example.org',
      opkCount: 2,
      pqOpkCount: 1,
      deviceId: 222,
    );

    final published = await _publishShaped(bob);
    final fetched = Omemo2Bundle.fromXml(
      _stripDeviceAttr(published.toXml()),
      jidOfBundle: bob.jid,
      deviceId: bob.id,
    );
    expect(fetched.deviceId, bob.id);

    final peer = await DualTrackManager.deviceFromBundle(fetched);
    expect(peer, isNotNull);
    expect(peer!.id, bob.id);

    final aliceLayer = PqMessageLayer(
      ownDevice: alice,
      sessions: PqSessionManager(kem: MlKem1024Provider.instance.kem),
      senderIkOf: (_, _) async => [],
    );
    final outgoing = await aliceLayer.encrypt(
      plaintext: 'hello via wire',
      recipients: [peer],
    );
    expect(outgoing, isNotNull);
    expect(outgoing!.stanza.keys.single.recipientDeviceId, bob.id);

    final onWire = PqEncryptedMessage.fromXml(outgoing.stanza.toXml());
    final bobLayer = PqMessageLayer(
      ownDevice: bob,
      sessions: PqSessionManager(kem: MlKem1024Provider.instance.kem),
      senderIkOf: (_, _) async => [],
    );
    final clear = await bobLayer.decrypt(onWire, senderBareJid: alice.jid);
    expect(clear, 'hello via wire');
  });
}
