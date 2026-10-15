// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Track-selection state machine (docs/02 §6) and codec round-trips.

import 'dart:convert';

import 'package:test/test.dart';
import 'package:xml/xml.dart';
import 'package:resonchat/crypto/omemo/bundle_codec.dart';
import 'package:resonchat/crypto/omemo/message_codec.dart';
import 'package:resonchat/crypto/omemo/negotiation.dart';
import 'package:resonchat/crypto/omemo/protocol.dart';
import 'package:resonchat/crypto/pq/kem_wire.dart';
import 'package:resonchat/crypto/pq/mlkem.dart';

XmlElement _rootOf(String fragment) => XmlDocument.parse(fragment).rootElement;

Omemo2Bundle _fullBundle() {
  final tagged = serializeMlKem1024PublicKey(
    List<int>.filled(MlKem1024.publicKeyLength, 7),
  );
  return Omemo2Bundle(
    deviceId: 4242,
    jid: 'me@example.org',
    spk: base64Encode(List<int>.filled(32, 1)),
    spkId: 7,
    spkSignature: base64Encode(List<int>.filled(64, 2)),
    ik: base64Encode(List<int>.filled(32, 3)),
    prekeys: {
      10: base64Encode(List<int>.filled(32, 4)),
      11: base64Encode(List<int>.filled(32, 5)),
    },
    kemSpkId: 1,
    kemSpk: base64Encode(tagged),
    kemSpkSignature: base64Encode(List<int>.filled(64, 6)),
    kemPrekeys: {20: base64Encode(tagged)},
    kemPrekeySignatures: {20: base64Encode(List<int>.filled(64, 8))},
    pqIk: base64Encode(List<int>.filled(2592, 9)),
    pqSig: base64Encode(List<int>.filled(4627, 10)),
  );
}

void main() {
  group('decideEncMode', () {
    test('empty recipient set cannot encrypt', () {
      expect(
        decideEncMode(allDevices: {}, pqCapable: {}, omemoCapable: {}),
        EncMode.none,
      );
    });

    test('all devices PQ-capable picks the B track', () {
      expect(
        decideEncMode(
          allDevices: {1, 2},
          pqCapable: {1, 2},
          omemoCapable: {1, 2},
        ),
        EncMode.pqOmemo,
      );
    });

    test('mixed devices fall back to standard OMEMO', () {
      expect(
        decideEncMode(allDevices: {1, 2}, pqCapable: {1}, omemoCapable: {1, 2}),
        EncMode.standardOmemo,
      );
    });

    test('a device with no bundle at all blocks encryption', () {
      expect(
        decideEncMode(
          allDevices: {1, 2, 3},
          pqCapable: {1, 2},
          omemoCapable: {1, 2},
        ),
        EncMode.none,
      );
    });

    test('capability sets must not include devices outside the chat', () {
      expect(
        decideEncMode(allDevices: {1}, pqCapable: {1, 9}, omemoCapable: {1}),
        EncMode.pqOmemo,
      );
      expect(
        decideEncMode(allDevices: {1}, pqCapable: {9}, omemoCapable: {1}),
        EncMode.standardOmemo,
      );
    });

    test('a device on neither track blocks encryption', () {
      expect(
        decideEncMode(allDevices: {1, 2}, pqCapable: {1}, omemoCapable: {1}),
        EncMode.none,
      );
    });

    test('PQ-only devices (no classic bundle) still pick the B track', () {
      // monocles can keep a live OMEMO2 bundle for an id whose axolotl
      // bundle no longer verifies — that device is reachable on B alone.
      expect(
        decideEncMode(allDevices: {5}, pqCapable: {5}, omemoCapable: {}),
        EncMode.pqOmemo,
      );
      expect(
        decideEncMode(allDevices: {1, 5}, pqCapable: {1, 5}, omemoCapable: {1}),
        EncMode.pqOmemo,
      );
    });
  });

  group('bundle codec', () {
    test('round-trips a full OMEMO2 bundle', () {
      final bundle = _fullBundle();
      final xml = bundle.toXml().toXmlString();
      expect(xml, contains(omemo2Xmlns));

      final parsed = Omemo2Bundle.fromXml(_rootOf(xml));
      expect(parsed.deviceId, _fullBundle().deviceId);
      expect(parsed.spkId, 7);
      expect(parsed.kemSpkId, 1);
      expect(parsed.hasPqIdentity, isTrue);
      expect(parsed.kemPrekeys.length, 1);
    });

    test('bundle without pq-sig is not hasPqIdentity', () {
      final bundle = Omemo2Bundle(
        deviceId: 7,
        jid: 'me@example.org',
        spk: base64Encode(List<int>.filled(32, 0)),
        spkId: 1,
        spkSignature: base64Encode(List<int>.filled(64, 0)),
        ik: base64Encode(List<int>.filled(32, 0)),
        prekeys: const {},
        kemSpkId: 1,
        kemSpk: base64Encode(
          serializeMlKem1024PublicKey(
            List<int>.filled(MlKem1024.publicKeyLength, 0),
          ),
        ),
        kemSpkSignature: base64Encode(List<int>.filled(64, 0)),
        kemPrekeys: const {},
        kemPrekeySignatures: const {},
        pqIk: '',
        pqSig: '',
      );
      expect(bundle.hasPqIdentity, isFalse);
    });
  });

  group('message codec', () {
    test('round-trips a KEX message with commit', () {
      final msg = PqEncryptedMessage(
        senderDeviceId: 123,
        recipients: [
          Omemo2KeysForJid(
            jid: 'bob@example.org',
            keys: [
              PqKeyEntry(
                recipientDeviceId: 456,
                ciphertext: 'U2lnbmFsUHJlS2V5',
                kex: true,
              ),
              PqKeyEntry(
                recipientDeviceId: 789,
                ciphertext: 'U2lnbmFsV2hpc3Blcg==',
              ),
            ],
          ),
        ],
        payload: 'cGF5bG9hZA==',
        commit: base64Encode(List<int>.filled(64, 1)),
      );
      final parsed = PqEncryptedMessage.fromXml(
        _rootOf(msg.toXml().toXmlString()),
      );

      expect(parsed.senderDeviceId, 123);
      expect(parsed.payload, 'cGF5bG9hZA==');
      expect(parsed.commit, isNotEmpty);
      expect(parsed.keys.length, 2);

      final kex = parsed.keys.first;
      expect(kex.recipientDeviceId, 456);
      expect(kex.kex, isTrue);
      expect(kex.ciphertext, 'U2lnbmFsUHJlS2V5');
    });

    test('uses the monocles OMEMO2 namespace, never urn:xmpp:omemo:2', () {
      final msg = PqEncryptedMessage(
        senderDeviceId: 1,
        recipients: [
          Omemo2KeysForJid(
            jid: 'a@b',
            keys: [PqKeyEntry(recipientDeviceId: 2, ciphertext: 'dw==')],
          ),
        ],
        payload: 'cA==',
        commit: base64Encode(List<int>.filled(64, 0)),
      );
      final xml = msg.toXml().toXmlString();
      expect(xml, contains(omemo2Xmlns));
      expect(xml, isNot(contains('urn:xmpp:omemo:2')));
      expect(xml, contains('<commit'));
    });
  });

  group('protocol constants', () {
    test('namespaces are monocles OMEMO2', () {
      expect(omemo2Xmlns, 'urn:monocles:omemo-pq:1');
      expect(omemo2DevicesXmlns, '$omemo2Xmlns:devices');
      expect(omemo2BundlesXmlns, '$omemo2Xmlns:bundles');
    });

    test('ML-KEM-1024 sizes are the FIPS 203 values', () {
      expect(MlKem1024.publicKeyLength, 1568);
      expect(MlKem1024.secretKeyLength, 3168);
      expect(MlKem1024.ciphertextLength, 1568);
      expect(MlKem1024.sharedSecretLength, 32);
    });
  });
}
