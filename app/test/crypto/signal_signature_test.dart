// XEdDSA self-consistency.
//
// OMEMO 0.3 makes every session depend on one primitive: the peer's signature
// over its own signed prekey, checked against its published identity key. A
// signed prekey we publish and cannot verify back would mean no Conversations
// client could ever start a session with us — and, symmetrically, that we
// cannot start one with anybody. Both directions were failing on device with
// "Invalid signature on device key!", so the primitive is pinned down here.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

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
}
