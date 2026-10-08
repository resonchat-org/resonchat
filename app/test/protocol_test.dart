// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Track-selection state machine (docs/02 §6) and codec round-trips.

import 'package:test/test.dart';
import 'package:xml/xml.dart';
import 'package:resonchat/omemo/bundle_codec.dart';
import 'package:resonchat/omemo/message_codec.dart';
import 'package:resonchat/omemo/negotiation.dart';
import 'package:resonchat/omemo/protocol.dart';
import 'package:resonchat/pq/mlkem.dart';

/// Parses a fragment and returns its first element.
XmlElement _rootOf(String fragment) => XmlDocument.parse(fragment).rootElement;

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
      // A stale cache listing extra PQ devices must not upgrade the track.
      expect(
        decideEncMode(allDevices: {1}, pqCapable: {1, 9}, omemoCapable: {1}),
        EncMode.pqOmemo,
      );
      expect(
        decideEncMode(allDevices: {1}, pqCapable: {9}, omemoCapable: {1}),
        EncMode.standardOmemo,
      );
    });

    test('untrusted devices force the safer fallback, never the B track', () {
      expect(
        decideEncMode(allDevices: {1, 2}, pqCapable: {1}, omemoCapable: {1}),
        EncMode.none,
      );
    });
  });

  group('bundle codec', () {
    test('round-trips a full PQ bundle', () {
      final bundle = PqBundle(
        deviceId: 4242,
        jid: 'me@example.org',
        spk: 'c3Br',
        spkId: 7,
        spkSignature: 'c2ln',
        ikEncoded: 'aWs=',
        prekeys: {10: 'cGswMQ==', 11: 'cGswMg=='},
        pqSpkId: 1,
        pqSpk: 'cHFzcGs=',
        pqSpkSignature: 'cHFzc2ln',
        pqPrekeys: {20: 'cHFwcGs='},
      );
      final xml = bundle.toXml().toXmlString();
      expect(xml, contains('urn:xmpp:pomemo:0'));

      final parsed = PqBundle.fromXml(_rootOf(xml));
      expect(parsed.deviceId, 4242);
      expect(parsed.spk, 'c3Br');
      expect(parsed.spkId, 7);
      expect(parsed.spkSignature, 'c2ln');
      expect(parsed.ikEncoded, 'aWs=');
      expect(parsed.prekeys, bundle.prekeys);
      expect(parsed.pqSpkId, 1);
      expect(parsed.pqSpk, 'cHFzcGs=');
      expect(parsed.pqSpkSignature, 'cHFzc2ln');
      expect(parsed.pqPrekeys, bundle.pqPrekeys);
      expect(parsed.hasPqKeys, isTrue);
    });

    test('bundle without PQ keys reports hasPqKeys false', () {
      final bundle = PqBundle(
        deviceId: 7,
        jid: 'me@example.org',
        spk: 'a',
        spkId: 1,
        spkSignature: 'b',
        ikEncoded: 'aWs=',
        prekeys: const {},
        pqSpkId: -1,
        pqSpk: '',
        pqSpkSignature: '',
        pqPrekeys: const {},
      );
      final parsed = PqBundle.fromXml(_rootOf(bundle.toXml().toXmlString()));
      expect(parsed.hasPqKeys, isFalse);
    });
  });

  group('message codec', () {
    test('round-trips a KEX message with two KEM ciphertexts', () {
      final msg = PqEncryptedMessage(
        senderDeviceId: 123,
        keys: [
          PqKeyEntry(
            recipientDeviceId: 456,
            wrap: 'd3JhcA==',
            kex: true,
            ek: 'ZWs=',
            spkId: 1,
            pkId: 10,
            pqSpkId: 2,
            pqPkId: 20,
            pqCiphertexts: const ['Y3Qx', 'Y3Qy'],
          ),
          PqKeyEntry(recipientDeviceId: 789, wrap: 'd3JhcDI='),
        ],
        iv: 'aXY=',
        payload: 'cGF5bG9hZA==',
      );
      final parsed = PqEncryptedMessage.fromXml(
        _rootOf(msg.toXml().toXmlString()),
      );

      expect(parsed.senderDeviceId, 123);
      expect(parsed.iv, 'aXY=');
      expect(parsed.payload, 'cGF5bG9hZA==');
      expect(parsed.keys.length, 2);

      final kex = parsed.keys.first;
      expect(kex.recipientDeviceId, 456);
      expect(kex.kex, isTrue);
      expect(kex.ek, 'ZWs=');
      expect(kex.spkId, 1);
      expect(kex.pkId, 10);
      expect(kex.pqSpkId, 2);
      expect(kex.pqPkId, 20);
      expect(kex.pqCiphertexts, ['Y3Qx', 'Y3Qy']);

      final steady = parsed.keys.last;
      expect(steady.recipientDeviceId, 789);
      expect(steady.kex, isFalse);
      expect(steady.pqCiphertexts, isEmpty);
    });

    test('uses the pomemo namespace, never the standard one', () {
      final msg = PqEncryptedMessage(
        senderDeviceId: 1,
        keys: [PqKeyEntry(recipientDeviceId: 2, wrap: 'dw==')],
        iv: 'aXY=',
        payload: 'cA==',
      );
      final xml = msg.toXml().toXmlString();
      expect(xml, contains(pomemoXmlns));
      expect(xml, isNot(contains('urn:xmpp:omemo:2')));
    });
  });

  group('protocol constants', () {
    test('namespaces are distinct from the standard track', () {
      expect(pomemoXmlns, isNot(contains('urn:xmpp:omemo:2')));
      expect(pomemoDevicesXmlns, '$pomemoXmlns:devices');
      expect(pomemoBundlesXmlns, '$pomemoXmlns:bundles');
    });

    test('ML-KEM-768 sizes are the FIPS 203 values', () {
      expect(MlKem768.publicKeyLength, 1184);
      expect(MlKem768.secretKeyLength, 2400);
      expect(MlKem768.ciphertextLength, 1088);
      expect(MlKem768.sharedSecretLength, 32);
    });
  });
}
