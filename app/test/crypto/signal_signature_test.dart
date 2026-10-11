// XEdDSA, and the gate built on it.
//
// OMEMO 0.3 makes every session depend on one primitive: the peer's signature
// over its own signed prekey, checked against its published identity key. A
// signed prekey we publish and cannot verify back would mean no Conversations
// client could ever start a session with us — and, symmetrically, that we
// cannot start one with anybody. Both directions were failing on device with
// "Invalid signature on device key!", so the primitive is pinned down here,
// together with [omemoBundleUsable], the check that decides whether a published
// device counts as reachable at all.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:omemo_dart/omemo_dart_axolotl.dart';
import 'package:resonchat/crypto/omemo/defacto.dart';

void main() {
  test('a signature we make over our own signed prekey verifies', () {
    // Exactly what omemo_dart publishes: generateSignedPreKey signs the
    // serialized public key of the prekey with the identity key.
    final identity = generateIdentityKeyPair();
    final signed = generateSignedPreKey(identity, 1234);

    expect(
      Curve.verifySignature(
        identity.getPublicKey().publicKey,
        signed.getKeyPair().publicKey.serialize(),
        signed.signature,
      ),
      isTrue,
      reason: 'our own published bundle must pass the check every client runs',
    );
  });

  test('the low-level primitive round-trips', () {
    final pair = Curve.generateKeyPair();
    final message = Uint8List.fromList(List<int>.filled(33, 0x05));

    final signature = Curve.calculateSignature(pair.privateKey, message);

    expect(signature.length, 64);
    expect(Curve.verifySignature(pair.publicKey, message, signature), isTrue);
  });

  test('a bundle we publish ourselves is usable, and one bit off is not', () async {
    // The gate that decides whether a device counts as reachable. A bundle
    // nobody can verify is a device that cannot be written to, and the send
    // path must skip it rather than fail on it.
    final device = await AxolotlDevice.generateNewDevice(
      'peer@example.org',
      preKeyCount: 4,
    );
    final bundle = await device.toBundle();
    expect(omemoBundleUsable(bundle), isTrue);

    // One flipped bit, which is what a signed prekey that no longer matches
    // its signature looks like from the outside.
    final signature = base64Decode(bundle.signedPreKeySignatureEncoded);
    signature[0] ^= 0x01;
    expect(
      omemoBundleUsable(
        AxolotlBundle(
          jid: bundle.jid,
          deviceId: bundle.deviceId,
          signedPreKeyId: bundle.signedPreKeyId,
          signedPreKeyPublicEncoded: bundle.signedPreKeyPublicEncoded,
          signedPreKeySignatureEncoded: base64Encode(signature),
          identityKeyEncoded: bundle.identityKeyEncoded,
          preKeysEncoded: bundle.preKeysEncoded,
        ),
      ),
      isFalse,
    );
  });

  test('a device that has handed out all of its prekeys is still usable', () async {
    // libsignal opens a session without a one-time prekey, and a device that
    // has given all of its own out still publishes a bundle with none.
    // Skipping it would drop somebody who is merely replenishing.
    final device = await AxolotlDevice.generateNewDevice(
      'peer@example.org',
      preKeyCount: 4,
    );
    final bundle = await device.toBundle();
    expect(
      omemoBundleUsable(
        AxolotlBundle(
          jid: bundle.jid,
          deviceId: bundle.deviceId,
          signedPreKeyId: bundle.signedPreKeyId,
          signedPreKeyPublicEncoded: bundle.signedPreKeyPublicEncoded,
          signedPreKeySignatureEncoded: bundle.signedPreKeySignatureEncoded,
          identityKeyEncoded: bundle.identityKeyEncoded,
          preKeysEncoded: const {},
        ),
      ),
      isTrue,
    );
  });
}
