// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// OMEMO2 bundle + deviceFromBundle (monocles wire).

import 'dart:convert';

import 'package:test/test.dart';
import 'package:resonchat/crypto/omemo/bundle_codec.dart';
import 'package:resonchat/crypto/omemo/dual_track_manager.dart';
import 'package:resonchat/crypto/omemo/protocol.dart';
import 'package:resonchat/crypto/pq/kem_wire.dart';
import 'package:resonchat/crypto/pq/mlkem.dart';
import 'package:resonchat/crypto/pq/pqcrypto_mlkem.dart';

Omemo2Bundle sampleBundle({required List<int> kemPk}) {
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
  );
}

void main() {
  final kem = PqcryptoMlKem1024();

  test('XML uses monocles OMEMO2 namespace and element names', () {
    final kp = kem.generateKeyPair();
    final b = sampleBundle(kemPk: kp.publicKey);
    final xml = b.toXml().toXmlString();
    expect(xml, contains(omemo2Xmlns));
    expect(xml, contains('<kem-spk'));
    expect(xml, contains('<pq-ik'));
    expect(xml, isNot(contains('urn:xmpp:pomemo:0')));
  });

  test('deviceFromBundle rebuilds a usable public PqDevice', () async {
    final kp = kem.generateKeyPair();
    final b = sampleBundle(kemPk: kp.publicKey);
    final device = await DualTrackManager.deviceFromBundle(b);
    expect(device, isNotNull);
    expect(device!.id, 7);
    expect(device.pqSpk.length, MlKem1024.publicKeyLength);
    expect(device.pqOpks.length, 1);
  });

  test('deviceFromBundle rejects Round-3 Kyber tag', () async {
    final bad = sampleBundle(
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
        kyber1024Round3Tag,
        ...List<int>.filled(MlKem1024.publicKeyLength, 0),
      ]),
      kemSpkSignature: bad.kemSpkSignature,
      kemPrekeys: bad.kemPrekeys,
      kemPrekeySignatures: bad.kemPrekeySignatures,
      pqIk: bad.pqIk,
      pqSig: bad.pqSig,
    );
    expect(await DualTrackManager.deviceFromBundle(mutated), isNull);
  });
}
