// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// App-path PQ round-trip: publish-shaped XML → fromXml(PEP item id) →
// deviceFromBundle → PqMessageLayer encrypt/decrypt with `<pq-auth>`.
//
// Mirrors monocles generateOmemo2Chat (OMEMO2 ciphertext only).

import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omemo_dart/omemo_dart_omemo2.dart';
import 'package:pqcrypto/pqcrypto.dart';
import 'package:xml/xml.dart';

import 'package:resonchat/crypto/dual/dual_track_manager.dart';
import 'package:resonchat/crypto/omemo2/bundle_codec.dart';
import 'package:resonchat/crypto/omemo2/message_codec.dart';
import 'package:resonchat/crypto/omemo2/pq_message_layer.dart';
import 'package:resonchat/crypto/omemo2/pq_session.dart';
import 'package:resonchat/persistence/database.dart';
import 'package:resonchat/persistence/omemo2_pq_pin_store.dart';
import 'package:resonchat/persistence/pq_identity_store.dart';

class _MemPqIdentity implements PqIdentityStore {
  _MemPqIdentity(this.pk, this.sk);

  final Uint8List pk;
  final Uint8List sk;

  @override
  String get accountId => 'test';

  @override
  Future<Uint8List> publicKey() async => pk;

  @override
  Future<(Uint8List, Uint8List)> keyPair() async => (pk, sk);

  @override
  Future<Uint8List> sign(Uint8List message) async {
    return MlDsa.sign(
      sk,
      message,
      DilithiumParams.mlDsa87,
      ctx: Uint8List.fromList(utf8.encode(omemo2PqIdContext)),
    );
  }

  @override
  Future<void> clear() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<(Omemo2Bundle, Uint8List, Uint8List)> _publishShaped(
  Omemo2Device device,
) async {
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
  for (final e in device.pqOpks.entries) {
    final tagged = serializeMlKem1024PublicKey(e.value.publicRaw);
    kemPrekeys[e.key] = base64Encode(tagged);
    kemSigs[e.key] = base64Encode(e.value.signature);
  }
  final (pqIk, pqSk) = MlDsa.generateKeyPair(DilithiumParams.mlDsa87);
  final transcript = await device.identityTranscript(pqIk);
  final pqSig = MlDsa.sign(
    pqSk,
    transcript,
    DilithiumParams.mlDsa87,
    ctx: Uint8List.fromList(utf8.encode(omemo2PqIdContext)),
  );
  final ikSig = await device.sign(transcript);
  return (
    Omemo2Bundle(
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
    ),
    pqIk,
    pqSk,
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

    final (published, bobPk, bobSk) = await _publishShaped(bob);
    final fetched = Omemo2Bundle.fromXml(
      _stripDeviceAttr(published.toXml()),
      jidOfBundle: bob.jid,
      deviceId: bob.id,
    );
    expect(fetched.deviceId, bob.id);

    final peer = await DualTrackManager.deviceFromBundle(fetched);
    expect(peer, isNotNull);
    expect(peer!.id, bob.id);

    final (alicePk, aliceSk) = MlDsa.generateKeyPair(DilithiumParams.mlDsa87);
    final aliceDb = AppDatabase(NativeDatabase.memory());
    final bobDb = AppDatabase(NativeDatabase.memory());
    addTearDown(aliceDb.close);
    addTearDown(bobDb.close);

    final aliceLayer = PqMessageLayer(
      ownDevice: alice,
      sessions: PqSessionManager(),
      pqIdentity: _MemPqIdentity(alicePk, aliceSk),
      pins: Omemo2PqPinStore(aliceDb),
    );
    final outgoing = await aliceLayer.encrypt(
      plaintext: 'hello via wire',
      recipients: [peer],
    );
    expect(outgoing, isNotNull);
    expect(outgoing!.stanza.keys.single.recipientDeviceId, bob.id);
    expect(outgoing.stanza.pqAuth, isNotNull);

    final onWire = PqEncryptedMessage.fromXml(outgoing.stanza.toXml());
    expect(onWire.pqAuth, isNotNull);
    final bobLayer = PqMessageLayer(
      ownDevice: bob,
      sessions: PqSessionManager(),
      pqIdentity: _MemPqIdentity(bobPk, bobSk),
      pins: Omemo2PqPinStore(bobDb),
    );
    final clear = await bobLayer.decrypt(onWire, senderBareJid: alice.jid);
    expect(clear, 'hello via wire');
  });
}
