// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:xml/xml.dart';
import 'package:resonchat/crypto/omemo/bundle_codec.dart';
import 'package:resonchat/crypto/omemo/protocol.dart';
import 'package:resonchat/crypto/pq/kem_wire.dart';
import 'package:resonchat/crypto/pq/mlkem.dart';

Omemo2Bundle _sample() {
  final rawPk = List<int>.filled(MlKem1024.publicKeyLength, 7);
  final tagged = serializeMlKem1024PublicKey(rawPk);
  return Omemo2Bundle(
    deviceId: 42,
    jid: 'alice@example.org',
    spk: base64Encode(List<int>.filled(32, 1)),
    spkId: 3,
    spkSignature: base64Encode(List<int>.filled(64, 2)),
    ik: base64Encode(List<int>.filled(32, 3)),
    prekeys: {9: base64Encode(List<int>.filled(32, 4))},
    kemSpkId: 5,
    kemSpk: base64Encode(tagged),
    kemSpkSignature: base64Encode(List<int>.filled(64, 6)),
    kemPrekeys: {7: base64Encode(tagged)},
    kemPrekeySignatures: {7: base64Encode(List<int>.filled(64, 8))},
    pqIk: base64Encode(List<int>.filled(2592, 9)),
    pqSig: base64Encode(List<int>.filled(4627, 10)),
  );
}

void main() {
  test('Omemo2Bundle round-trips monocles element names', () {
    final bundle = _sample();
    final xml = bundle.toXml().toXmlString();
    expect(xml, contains(omemo2Xmlns));
    expect(xml, contains('kem-spk'));
    expect(xml, contains('pq-ik'));
    expect(xml, contains('pq-sig'));
    expect(xml, isNot(contains('pqspk')));

    final back = Omemo2Bundle.fromXml(bundle.toXml(), jidOfBundle: bundle.jid);
    expect(back.deviceId, 42);
    expect(back.spkId, 3);
    expect(back.kemSpkId, 5);
    expect(back.hasPqIdentity, isTrue);
    expect(back.ikSerialized.first, 0x05);
    expect(isMlKem1024PublicKey(base64Decode(back.kemSpk)), isTrue);
  });

  test('PEP item id overrides missing device attribute', () {
    // Historical publishes omitted device= on the payload; the PEP item id
    // is still the real device id. Without that override every peer looked
    // like device 0 and decrypt filtered keys away.
    final xml = _sample().toXml().toXmlString().replaceFirst(
      ' device="42"',
      '',
    );
    final parsed = Omemo2Bundle.fromXml(
      XmlDocument.parse(xml).rootElement,
      deviceId: 99,
    );
    expect(parsed.deviceId, 99);
  });

  test('refuses bundle with no device id at all', () {
    final xml = _sample().toXml().toXmlString().replaceFirst(
      ' device="42"',
      '',
    );
    expect(
      () => Omemo2Bundle.fromXml(XmlDocument.parse(xml).rootElement),
      throwsA(isA<FormatException>()),
    );
  });

  test('refuses wrong pq-ik type', () {
    final badXml = _sample().toXml().toXmlString().replaceFirst(
      'ML-DSA-87',
      'ML-DSA-65',
    );
    expect(
      () => Omemo2Bundle.fromXml(XmlDocument.parse(badXml).rootElement),
      throwsA(isA<FormatException>()),
    );
  });

  test('kem_wire refuses Round-3 Kyber tag', () {
    final bad = Uint8List.fromList([
      kyber1024Round3Tag,
      ...List<int>.filled(MlKem1024.publicKeyLength, 0),
    ]);
    expect(() => parseMlKem1024PublicKey(bad), throwsFormatException);
  });
}
