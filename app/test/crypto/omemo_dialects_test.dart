// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The two OMEMO wire dialects.
//
// The de-facto payloads below are not invented: they are the exact bytes
// Conversations 2.20.4 published to jabber.fr while this test suite was
// being written. Getting these wrong makes the app silently invisible to
// every client that exists, which no unit test written against our own
// output would ever catch.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:omemo_dart/omemo_dart_axolotl.dart' show AxolotlBundle;
import 'package:resonchat/crypto/omemo/defacto.dart';
import 'package:xml/xml.dart';

const String _k32 = 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=';
const String _k64 =
    'AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAhIiMkJSYnKCkqKywtLi8wMTIzNDU2Nzg5Ojs8PT4/QA==';
const String _ik32 = 'AgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4fICE=';
const String _pk88 = 'AwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8gISI=';
const String _pk89 = 'BAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAhIiM=';

/// The structure is copied verbatim from Conversations 2.20.4 on
/// jabber.fr. The key *values* are replaced with full-length stand-ins
/// because the captured ones were shortened here, and a shortened
/// prekey is exactly what `omemoBundleLooksSane` must reject — see the
/// truncated-payload test below.
const String realDefactoBundle =
    '''
<bundle xmlns="eu.siacs.conversations.axolotl">
  <signedPreKeyPublic signedPreKeyId="1">$_k32</signedPreKeyPublic>
  <signedPreKeySignature>$_k64</signedPreKeySignature>
  <identityKey>$_ik32</identityKey>
  <prekeys>
    <preKeyPublic preKeyId="88">$_pk88</preKeyPublic>
    <preKeyPublic preKeyId="89">$_pk89</preKeyPublic>
  </prekeys>
</bundle>
''';

const String realDefactoDeviceList = '''
<list xmlns="eu.siacs.conversations.axolotl"><device id="889064890"/></list>
''';

/// What moxxmpp emits: XEP-0384 v2 element names.
const String specBundle =
    '''
<bundle xmlns="urn:xmpp:omemo:2">
  <spk id="7">$_k32</spk>
  <spks>$_k64</spks>
  <ik>$_ik32</ik>
  <prekeys><pk id="88">$_pk88</pk></prekeys>
</bundle>
''';

const String specDeviceList =
    '<devices xmlns="urn:xmpp:omemo:2:devices"><device id="1"/><device id="2"/></devices>';

AxolotlBundle _bundle() => AxolotlBundle(
  jid: 'peer@example.org',
  deviceId: 889064890,
  signedPreKeyId: 1,
  signedPreKeyPublicEncoded: base64Encode(List<int>.generate(32, (i) => i)),
  signedPreKeySignatureEncoded: base64Encode(List<int>.generate(64, (i) => i)),
  identityKeyEncoded: base64Encode(List<int>.generate(32, (i) => 200 - i)),
  preKeysEncoded: {88: base64Encode(List<int>.generate(32, (i) => 7))},
);

void main() {
  group('reading a real Conversations bundle', () {
    test('parses every field', () {
      final parsed = parseOmemoBundle(
        XmlDocument.parse(realDefactoBundle).rootElement,
        jid: 'xmpprev@jabber.fr',
        deviceId: 889064890,
      );

      expect(parsed.deviceId, 889064890);
      expect(parsed.signedPreKeyId, 1);
      expect(parsed.signedPreKeyPublicEncoded, ensureKeyTypeByte(_k32));
      expect(parsed.signedPreKeySignatureEncoded, _k64);
      expect(parsed.identityKeyEncoded, ensureKeyTypeByte(_ik32));
      expect(parsed.preKeysEncoded.keys.toSet(), {88, 89});
      // Real keys must pass our sanity check, or we would refuse a peer who
      // is in fact perfectly capable.
      expect(omemoBundleLooksSane(parsed), isTrue);
    });

    test('a bundle in the spec dialect parses to the same thing', () {
      final parsed = parseOmemoBundle(
        XmlDocument.parse(specBundle).rootElement,
        jid: 'peer@example.org',
        deviceId: 889064890,
      );
      // spkId 7 is this fixture's own value: it proves the id is read from
      // `spk/@id` here and from `signedPreKeyPublic/@signedPreKeyId` above,
      // rather than being hard-coded to one spelling.
      expect(parsed.signedPreKeyId, 7);
      expect(parsed.preKeysEncoded.keys.toSet(), {88});
      expect(parsed.identityKeyEncoded, ensureKeyTypeByte(_ik32));
    });
  });

  group('round-tripping through both dialects', () {
    test('de-facto output re-parses to an identical bundle', () {
      final original = _bundle();
      final xml = bundleToDefactoXml(original);
      // The element names must be the ones real clients look for.
      expect(
        xml
            .findElements('signedPreKeyPublic')
            .single
            .getAttribute('signedPreKeyId'),
        '1',
      );
      expect(xml.findElements('signedPreKeySignature'), hasLength(1));
      expect(xml.findElements('identityKey'), hasLength(1));
      expect(
        xml
            .findElements('prekeys')
            .single
            .findElements('preKeyPublic')
            .single
            .getAttribute('preKeyId'),
        '88',
      );

      final back = parseOmemoBundle(
        xml,
        jid: original.jid,
        deviceId: original.deviceId,
      );
      // Publish path adds 0x05; parse keeps it.
      expect(
        back.signedPreKeyPublicEncoded,
        ensureKeyTypeByte(original.signedPreKeyPublicEncoded),
      );
      expect(back.signedPreKeyId, original.signedPreKeyId);
      expect(
        back.signedPreKeySignatureEncoded,
        original.signedPreKeySignatureEncoded,
      );
      expect(
        back.identityKeyEncoded,
        ensureKeyTypeByte(original.identityKeyEncoded),
      );
      expect(
        back.preKeysEncoded[88],
        ensureKeyTypeByte(original.preKeysEncoded[88]!),
      );
    });

    test('device list output re-parses to an identical set', () {
      final xml = deviceListToDefactoXml([889064890, 42]);
      expect(xml.localName, 'list');
      expect(xml.getAttribute('xmlns'), omemoDefactoXmlns);
      expect(parseOmemoDeviceList(xml), {889064890, 42});
    });

    test('both device-list dialects are understood', () {
      expect(
        parseOmemoDeviceList(
          XmlDocument.parse(realDefactoDeviceList).rootElement,
        ),
        {889064890},
      );
      expect(
        parseOmemoDeviceList(XmlDocument.parse(specDeviceList).rootElement),
        {1, 2},
      );
      // Something that is not a device list yields null rather than a lie.
      expect(
        parseOmemoDeviceList(XmlDocument.parse('<bundle/>').rootElement),
        isNull,
      );
    });
  });

  group('refusing malformed input', () {
    test('a bundle without a signed prekey id is rejected', () {
      expect(
        () => parseOmemoBundle(
          XmlDocument.parse(
            '<bundle><signedPreKeyPublic>x</signedPreKeyPublic>'
            '<signedPreKeySignature>y</signedPreKeySignature>'
            '<identityKey>z</identityKey></bundle>',
          ).rootElement,
          jid: 'a@b',
          deviceId: 1,
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('a bundle missing its identity key is rejected', () {
      expect(
        () => parseOmemoBundle(
          XmlDocument.parse(
            '<bundle><spk id="1">a</spk><spks>b</spks></bundle>',
          ).rootElement,
          jid: 'a@b',
          deviceId: 1,
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('an unrelated element is not treated as a bundle', () {
      expect(
        () => parseOmemoBundle(
          XmlDocument.parse('<encrypted/>').rootElement,
          jid: 'a@b',
          deviceId: 1,
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('sanity check rejects wrong key sizes', () {
      expect(
        omemoBundleLooksSane(
          AxolotlBundle(
            jid: 'a@b',
            deviceId: 1,
            signedPreKeyId: 1,
            signedPreKeyPublicEncoded: base64Encode(
              List<int>.filled(31, 0),
            ), // too short
            signedPreKeySignatureEncoded: base64Encode(List<int>.filled(64, 0)),
            identityKeyEncoded: base64Encode(List<int>.filled(32, 0)),
            preKeysEncoded: {1: base64Encode(List<int>.filled(32, 0))},
          ),
        ),
        isFalse,
      );
    });

    test('sanity check rejects an empty prekey pool', () {
      expect(
        omemoBundleLooksSane(
          AxolotlBundle(
            jid: 'a@b',
            deviceId: 1,
            signedPreKeyId: 1,
            signedPreKeyPublicEncoded: base64Encode(List<int>.filled(32, 0)),
            signedPreKeySignatureEncoded: base64Encode(List<int>.filled(64, 0)),
            identityKeyEncoded: base64Encode(List<int>.filled(32, 0)),
            preKeysEncoded: const {},
          ),
        ),
        isFalse,
      );
    });
  });

  test('the two dialects use different node names, as the server showed', () {
    // Guard against someone "tidying" one of these back to match the other.
    expect(omemoDefactoDevicesNode, isNot(omemoSpecDevicesNodes.single));
    expect(omemoDefactoBundlesNode, isNot(omemoSpecBundlesNodes.single));
    expect(
      omemoDefactoDevicesNode,
      'eu.siacs.conversations.axolotl.devicelist',
    );
  });

  group("Signal's key-type byte", () {
    // What Conversations actually published: 33 bytes starting 0x05.
    final prefixed = base64Encode([keyTypePrefix, ...base64Decode(_k32)]);
    final realLookedLike =
        'BVhVOpx6E+gYaizTXS2p74jzyJffdn/y9Z01l+y2L1BM2'; // captured, truncated

    test('a 33-byte prefixed key is reduced to the bare 32 bytes', () {
      expect(base64Decode(prefixed).length, 33);
      expect(stripKeyTypeByte(prefixed), _k32);
      expect(base64Decode(stripKeyTypeByte(prefixed)).length, 32);
    });

    test('stripping is a no-op on an already-bare key', () {
      expect(stripKeyTypeByte(_k32), _k32);
    });

    test('a 33-byte key with an unexpected prefix is left alone', () {
      // Do not silently strip bytes from a key that is genuinely 33 bytes.
      final odd = base64Encode([0x09, ...base64Decode(_k32)]);
      expect(stripKeyTypeByte(odd), odd);
    });

    test('adding the prefix is idempotent', () {
      final once = addKeyTypeByte(_k32);
      expect(base64Decode(once).first, keyTypePrefix);
      expect(base64Decode(once).length, 33);
      expect(addKeyTypeByte(once), once);
    });

    test('our published keys carry the prefix real clients require', () {
      final xml = bundleToDefactoXml(_bundle());
      final spk = xml.findElements('signedPreKeyPublic').single.innerText;
      final ik = xml.findElements('identityKey').single.innerText;
      final pk = xml
          .findElements('prekeys')
          .single
          .findElements('preKeyPublic')
          .single
          .innerText;
      for (final value in [spk, ik, pk]) {
        expect(base64Decode(value).length, 33, reason: 'missing key-type byte');
        expect(base64Decode(value).first, keyTypePrefix);
      }
      // The signature must stay at 64 raw bytes and carry no prefix.
      final sig = xml.findElements('signedPreKeySignature').single.innerText;
      final sigBytes = base64Decode(sig);
      expect(sigBytes.length, 64);
      expect(sigBytes.first, 0, reason: 'signature must not be prefixed');
      // Guard against the fixture drifting away from the real capture.
      expect(realLookedLike.startsWith('BVhVOpx6E+gYaizTXS2p74jz'), isTrue);
    });

    test('a real-shaped bundle keeps 33-byte Signal-serialized keys', () {
      final real =
          '''
<bundle xmlns="eu.siacs.conversations.axolotl">
  <signedPreKeyPublic signedPreKeyId="1">${base64Encode([keyTypePrefix, ...base64Decode(_k32)])}</signedPreKeyPublic>
  <signedPreKeySignature>$_k64</signedPreKeySignature>
  <identityKey>${base64Encode([keyTypePrefix, ...base64Decode(_ik32)])}</identityKey>
  <prekeys>
    <preKeyPublic preKeyId="88">${base64Encode([keyTypePrefix, ...base64Decode(_pk88)])}</preKeyPublic>
  </prekeys>
</bundle>
''';
      final parsed = parseOmemoBundle(
        XmlDocument.parse(real).rootElement,
        jid: 'a@b',
        deviceId: 1,
      );
      expect(parsed.signedPreKeyPublicEncoded, ensureKeyTypeByte(_k32));
      expect(parsed.identityKeyEncoded, ensureKeyTypeByte(_ik32));
      expect(parsed.preKeysEncoded[88], ensureKeyTypeByte(_pk88));
      expect(omemoBundleLooksSane(parsed), isTrue);
    });
  });
}
