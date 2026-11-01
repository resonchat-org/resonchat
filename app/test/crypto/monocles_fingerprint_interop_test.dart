// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Cross-check hybrid fingerprints against monocles' construction:
//   getOwnHybridFingerprint =
//     CryptoHelper.hybridOmemo2Fingerprint(
//       identityKeyPair.publicKey.serialize(),  // 33B with 0x05
//       pqIdentityKeyPair.publicKey.serialize() // 2592B ML-DSA-87
//     )
// Keys are generated with libsignal's PqIdentityKeyPair / IdentityKeyPair
// (same API monocles uses via org.signal.libsignal.protocol.pqid).

import 'dart:convert';
import 'dart:typed_data';

import 'package:hex/hex.dart';
import 'package:libsignal/libsignal.dart' as ls;
import 'package:omemo_dart/omemo_dart_omemo2.dart';
import 'package:pqcrypto/pqcrypto.dart';
import 'package:test/test.dart';
import 'package:xml/xml.dart';

import 'package:resonchat/crypto/omemo2/bundle_codec.dart';
import 'package:resonchat/crypto/omemo2/protocol.dart';

void main() {
  setUpAll(() async {
    await ls.LibSignal.init();
  });

  group('monocles hybrid fingerprint interop', () {
    test('KAT matches monocles CryptoHelperTest / proto-XEP §4.9.3', () {
      final ik = Uint8List(33);
      ik[0] = 0x05;
      for (var i = 1; i < 33; i++) {
        ik[i] = 0x11;
      }
      final pq = Uint8List(2592);
      for (var i = 0; i < pq.length; i++) {
        pq[i] = 0x22;
      }
      const want =
          '6b6ea370b7cbc0078f992487b235ab384a7f272b232e508a2d27da9b42f1def7'
          'f2def0daffbdfd91a33065c1e383473a1eacce6e5709833d286c5e399e19c77a';
      expect(hybridOmemo2Fingerprint(ik, pq), want);
    });

    test('libsignal-generated IK+PQ (monocles API) → publish XML → ResonChat parse '
        'yields the same hybrid fingerprint monocles would show for own device', () {
      // monocles: IdentityKeyPair + PqIdentityKeyPair.generate()
      final idPair = ls.IdentityKeyPair.generate();
      final pqPair = ls.PqIdentityKeyPair.generate();

      final ikTagged = Uint8List.fromList(idPair.publicKey);
      expect(ikTagged.length, 33);
      expect(ikTagged.first, 0x05);

      final pqIk = Uint8List.fromList(pqPair.publicKey().serialize());
      expect(pqIk.length, 2592);

      // What monocles EditAccount / getOwnHybridFingerprint shows.
      final monoclesOwn = hybridOmemo2Fingerprint(ikTagged, pqIk);

      // What monocles puts on the wire (IqGenerator): raw 32-byte ik, raw pq-ik.
      final wireIk = base64Encode(ikTagged.sublist(1));
      final wirePq = base64Encode(pqIk);

      final xml = _minimalMonoclesBundleXml(
        deviceId: 4242,
        ikB64: wireIk,
        pqIkB64: wirePq,
      );

      final parsed = Omemo2Bundle.fromXml(XmlDocument.parse(xml).rootElement);
      expect(parsed.pqIk, isNotEmpty);
      // Fingerprint refresh only needs ik + pq-ik:
      final fromWire = hybridOmemo2Fingerprint(
        parsed.ikSerialized,
        Uint8List.fromList(base64Decode(parsed.pqIk)),
      );

      expect(
        fromWire,
        monoclesOwn,
        reason:
            'ResonChat fingerprint from monocles-shaped PEP bundle must equal '
            'monocles getOwnHybridFingerprint for the same keys',
      );
      expect(fromWire.length, 128);
    });

    test('ResonChat pqcrypto ML-DSA-87 public keys are 2592B and accepted by '
        'libsignal PqIdentityKey (wire format parity)', () {
      final (pk, _) = MlDsa.generateKeyPair(DilithiumParams.mlDsa87);
      expect(pk.length, 2592);

      // monocles / libsignal deserialize the published <pq-ik> bytes.
      final accepted = ls.PqIdentityKey.deserialize(bytes: pk);
      expect(accepted.serialize(), pk);

      final idPair = ls.IdentityKeyPair.generate();
      final ik = Uint8List.fromList(idPair.publicKey);
      final fp = hybridOmemo2Fingerprint(ik, Uint8List.fromList(pk));
      expect(fp.length, 128);

      // Round-trip through ResonChat bundle codec.
      final xml = _minimalMonoclesBundleXml(
        deviceId: 7,
        ikB64: base64Encode(ik.sublist(1)),
        pqIkB64: base64Encode(pk),
      );
      final parsed = Omemo2Bundle.fromXml(XmlDocument.parse(xml).rootElement);
      expect(
        hybridOmemo2Fingerprint(
          parsed.ikSerialized,
          Uint8List.fromList(base64Decode(parsed.pqIk)),
        ),
        fp,
      );
    });

    test(
      'pqcrypto signature under monocles:omemo2:pqid:v1 verifies in libsignal',
      () {
        final (pk, sk) = MlDsa.generateKeyPair(DilithiumParams.mlDsa87);
        final msg = Uint8List.fromList(utf8.encode('bundle-transcript-v4'));
        final ctx = Uint8List.fromList(utf8.encode(omemo2PqIdContext));
        final sig = MlDsa.sign(sk, msg, DilithiumParams.mlDsa87, ctx: ctx);

        final lsPk = ls.PqIdentityKey.deserialize(bytes: pk);
        final lsSig = ls.PqSignature.deserialize(bytes: sig);
        expect(
          lsPk.verify(message: msg, signature: lsSig),
          isTrue,
          reason:
              'If this fails, monocles cannot verify ResonChat <pq-sig> — '
              'underlying ML-DSA stacks disagree',
        );
      },
    );

    test('libsignal signature under pqid:v1 verifies in pqcrypto', () {
      final pqPair = ls.PqIdentityKeyPair.generate();
      final pk = pqPair.publicKey().serialize();
      final msg = Uint8List.fromList(utf8.encode('bundle-transcript-v4'));
      final sig = pqPair.sign(message: msg).serialize();

      expect(
        MlDsa.verify(
          Uint8List.fromList(pk),
          msg,
          Uint8List.fromList(sig),
          DilithiumParams.mlDsa87,
          ctx: Uint8List.fromList(utf8.encode(omemo2PqIdContext)),
        ),
        isTrue,
        reason: 'If this fails, ResonChat cannot verify monocles <pq-sig>',
      );
    });

    test(
      'classical trust key is 66-hex 05‖ik (monocles bytesToHex(serialize))',
      () {
        final idPair = ls.IdentityKeyPair.generate();
        final ik = Uint8List.fromList(idPair.publicKey);
        final monoclesClassical = HEX.encode(ik).toLowerCase();
        expect(monoclesClassical.length, 66);
        expect(monoclesClassical.startsWith('05'), isTrue);

        final pq = ls.PqIdentityKeyPair.generate().publicKey().serialize();
        final hybrid = hybridOmemo2Fingerprint(ik, Uint8List.fromList(pq));
        expect(hybrid, isNot(monoclesClassical));
        expect(hybrid.length, 128);
      },
    );
  });
}

/// Minimal monocles-shaped `<bundle>` carrying only the identity halves needed
/// for fingerprint checks (signatures / KEM stubs are placeholders).
String _minimalMonoclesBundleXml({
  required int deviceId,
  required String ikB64,
  required String pqIkB64,
}) {
  return '''
<bundle xmlns="$omemo2Xmlns" rev="4" device="$deviceId">
  <spk id="1">${base64Encode(Uint8List(32))}</spk>
  <spks>${base64Encode(Uint8List(64))}</spks>
  <ik>$ikB64</ik>
  <prekeys><pk id="1">${base64Encode(Uint8List(32))}</pk></prekeys>
  <kem-spk id="1">${base64Encode(Uint8List.fromList([0x0A, ...Uint8List(1568)]))}</kem-spk>
  <kem-spks>${base64Encode(Uint8List(64))}</kem-spks>
  <kem-prekeys/>
  <pq-ik type="$omemo2PqIkAlgorithm">$pqIkB64</pq-ik>
  <pq-sig>${base64Encode(Uint8List(4627))}</pq-sig>
  <ik-sig>${base64Encode(Uint8List(64))}</ik-sig>
</bundle>
''';
}
