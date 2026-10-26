// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// OMEMO2 bundle + deviceFromBundle (monocles wire).

import 'dart:convert';
import 'dart:typed_data';

import 'package:omemo_dart/omemo_dart_omemo2.dart';
import 'package:pqcrypto/pqcrypto.dart';
import 'package:test/test.dart';
import 'package:xml/xml.dart';

import 'package:resonchat/crypto/dual/dual_track_manager.dart';
import 'package:resonchat/crypto/omemo2/bundle_codec.dart';
import 'package:resonchat/crypto/omemo2/mlkem.dart';
import 'package:resonchat/crypto/omemo2/protocol.dart';

/// Publish-shaped bundle with real pq-sig + ik-sig (monocles v4).
Future<Omemo2Bundle> _signedPublish(Omemo2Device device) async {
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

Omemo2Bundle sampleUnsigned({required List<int> kemPk}) {
  final tagged = serializeMlKem1024PublicKey(kemPk);
  return Omemo2Bundle(
    deviceId: 7,
    jid: 'bob@example.org',
    spk: base64Encode(List<int>.filled(32, 1)),
    spkId: 3,
    spkSignature: base64Encode(List<int>.filled(64, 2)),
    ik: base64Encode(List<int>.filled(32, 3)),
    prekeys: {11: base64Encode(List<int>.filled(32, 4))},
    kemSpkId: 5,
    kemSpk: base64Encode(tagged),
    kemSpkSignature: base64Encode(List<int>.filled(64, 6)),
    kemPrekeys: {13: base64Encode(tagged)},
    kemPrekeySignatures: {13: base64Encode(List<int>.filled(64, 8))},
    pqIk: base64Encode(List<int>.filled(2592, 9)),
    pqSig: base64Encode(List<int>.filled(4627, 10)),
    ikSig: base64Encode(List<int>.filled(64, 11)),
  );
}

void main() {
  setUpAll(() async {
    await omemo2EnsureLibSignal();
  });

  test('XML uses monocles OMEMO2 namespace and element names', () {
    final b = sampleUnsigned(
      kemPk: List<int>.filled(MlKem1024.publicKeyLength, 1),
    );
    final xml = b.toXml().toXmlString();
    expect(xml, contains(omemo2Xmlns));
    expect(xml, contains('<kem-spk'));
    expect(xml, contains('<pq-ik'));
    expect(xml, contains('<ik-sig'));
    expect(xml, isNot(contains('urn:xmpp:pomemo:0')));
  });

  test('deviceFromBundle rebuilds a usable public PqDevice', () async {
    final bob = await Omemo2Device.generate(
      'bob@example.org',
      opkCount: 2,
      pqOpkCount: 1,
      deviceId: 7,
    );
    final b = await _signedPublish(bob);
    final device = await DualTrackManager.deviceFromBundle(b);
    expect(device, isNotNull);
    expect(device!.id, 7);
    expect(device.pqSpk.length, MlKem1024.publicKeyLength);
    expect(device.pqOpks.length, 1);
    expect(device.peerIkSignature, isNotNull);
  });

  test(
    'PEP-wrapped base64 still verifies (monocles strips whitespace)',
    () async {
      final bob = await Omemo2Device.generate(
        'bob@example.org',
        opkCount: 1,
        pqOpkCount: 1,
        deviceId: 9,
      );
      final b = await _signedPublish(bob);
      String wrap(String b64) {
        final buf = StringBuffer();
        for (var i = 0; i < b64.length; i += 64) {
          if (i > 0) buf.write('\n');
          final end = i + 64 < b64.length ? i + 64 : b64.length;
          buf.write(b64.substring(i, end));
        }
        return buf.toString();
      }

      final xml = b
          .toXml()
          .toXmlString()
          .replaceFirst(b.pqSig, wrap(b.pqSig))
          .replaceFirst(b.ikSig, wrap(b.ikSig))
          .replaceFirst(b.kemSpk, wrap(b.kemSpk));
      final parsed = Omemo2Bundle.fromXml(
        XmlDocument.parse(xml).rootElement,
        jidOfBundle: b.jid,
      );
      expect(parsed.pqSig, b.pqSig);
      expect(parsed.ikSig, b.ikSig);
      expect(await DualTrackManager.deviceFromBundle(parsed), isNotNull);
    },
  );

  test(
    'deviceFromBundle refuses incomplete / invalid hybrid identity',
    () async {
      final bob = await Omemo2Device.generate(
        'bob@example.org',
        opkCount: 1,
        pqOpkCount: 1,
        deviceId: 8,
      );
      final good = await _signedPublish(bob);
      final noIkSig = Omemo2Bundle(
        deviceId: good.deviceId,
        jid: good.jid,
        spk: good.spk,
        spkId: good.spkId,
        spkSignature: good.spkSignature,
        ik: good.ik,
        prekeys: good.prekeys,
        kemSpkId: good.kemSpkId,
        kemSpk: good.kemSpk,
        kemSpkSignature: good.kemSpkSignature,
        kemPrekeys: good.kemPrekeys,
        kemPrekeySignatures: good.kemPrekeySignatures,
        pqIk: good.pqIk,
        pqSig: good.pqSig,
        ikSig: '',
      );
      expect(await DualTrackManager.deviceFromBundle(noIkSig), isNull);

      final badIkSig = Omemo2Bundle(
        deviceId: good.deviceId,
        jid: good.jid,
        spk: good.spk,
        spkId: good.spkId,
        spkSignature: good.spkSignature,
        ik: good.ik,
        prekeys: good.prekeys,
        kemSpkId: good.kemSpkId,
        kemSpk: good.kemSpk,
        kemSpkSignature: good.kemSpkSignature,
        kemPrekeys: good.kemPrekeys,
        kemPrekeySignatures: good.kemPrekeySignatures,
        pqIk: good.pqIk,
        pqSig: good.pqSig,
        ikSig: base64Encode(List<int>.filled(64, 0xff)),
      );
      expect(await DualTrackManager.deviceFromBundle(badIkSig), isNull);
    },
  );

  test('deviceFromBundle rejects Round-3 Kyber tag', () async {
    final bad = sampleUnsigned(
      kemPk: List<int>.filled(MlKem1024.publicKeyLength, 1),
    );
    final mutated = Omemo2Bundle(
      deviceId: bad.deviceId,
      jid: bad.jid,
      spk: bad.spk,
      spkId: bad.spkId,
      spkSignature: bad.spkSignature,
      ik: bad.ik,
      prekeys: bad.prekeys,
      kemSpkId: bad.kemSpkId,
      kemSpk: base64Encode([
        omemo2Kyber1024Round3Tag,
        ...List<int>.filled(MlKem1024.publicKeyLength, 0),
      ]),
      kemSpkSignature: bad.kemSpkSignature,
      kemPrekeys: bad.kemPrekeys,
      kemPrekeySignatures: bad.kemPrekeySignatures,
      pqIk: bad.pqIk,
      pqSig: bad.pqSig,
      ikSig: bad.ikSig,
    );
    expect(await DualTrackManager.deviceFromBundle(mutated), isNull);
  });
}
