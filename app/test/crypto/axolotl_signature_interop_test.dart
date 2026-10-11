// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The interop assertion a real Conversations install makes before it will
// encrypt to us, reproduced with the peer's own library.
//
// libsignal's SessionBuilder does, verbatim:
//
//   if (preKey.getSignedPreKey() != null &&
//       !Curve.verifySignature(preKey.getIdentityKey().getPublicKey(),
//                              preKey.getSignedPreKey().serialize(),
//                              preKey.getSignedPreKeySignature()))
//   {
//     throw new InvalidKeyException("Invalid signature on device key!");
//   }
//
// and that exception is what the peer logged, over and over, while refusing to
// build a session. The message is `signedPreKey.serialize()`:
//
//   Uint8List serialize() => Uint8List.fromList([Curve.djbType] + _publicKey);
//
// i.e. 33 bytes, type byte first — *not* the bare 32-byte key, and not the
// identity key concatenated with it. A hand-rolled stack that signs and
// verifies the bare 32 bytes is perfectly self-consistent and rejected by
// every real client, which is exactly the failure this test exists to
// prevent from coming back.
//
// Everything below goes through `libsignal_protocol_dart`, the same library
// the peer's stack is a port of, so this is not our verifier agreeing with our
// signer: it is the peer's check, run locally.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

// `libsignal_protocol_dart` is a transitive dependency of omemo_dart, not a
// direct one. That is deliberate: this test exists precisely to check our
// output against *the peer's* library, so it reaches for the real thing rather
// than re-exporting it through omemo_dart (which could hide a version skew
// behind a single pubspec edit). Bringing it in as a direct dependency would
// re-resolve the whole graph and move ~40 unrelated transitive versions, which
// is a much larger change than one line of test.
// ignore: depend_on_referenced_packages
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:omemo_dart/omemo_dart_axolotl.dart';

void main() {
  group('axolotl (Conversations) bundle signature', () {
    test('verifies exactly as SessionBuilder verifies it', () async {
      final device = await AxolotlDevice.generateNewDevice(
        'me@example.org',
        preKeyCount: 4,
      );
      final bundle = await device.toBundle();

      // The published form is libsignal's serialize() output: type byte + key.
      expect(
        bundle.identityKey.publicKey.serialize(),
        hasLength(33),
        reason: 'identity key serializes with the 0x05 type byte',
      );
      expect(bundle.identityKey.publicKey.serialize().first, Curve.djbType);
      expect(bundle.signedPreKeyPublic.serialize(), hasLength(33));
      expect(bundle.signedPreKeyPublic.serialize().first, Curve.djbType);
      expect(bundle.signedPreKeySignature, hasLength(64));

      // The peer's assertion. If this is false the peer throws
      // "Invalid signature on device key!" and encrypts nothing to us.
      expect(
        Curve.verifySignature(
          bundle.identityKey.publicKey,
          bundle.signedPreKeyPublic.serialize(),
          bundle.signedPreKeySignature,
        ),
        isTrue,
        reason: 'SessionBuilder must accept our signed prekey',
      );
    });

    test('the bare 32-byte key is not the signed message', () async {
      // Guards the specific mistake: signing the raw key. It verifies against
      // our own signer and against nobody else, so the test that only checks
      // "does our signature verify" would pass while the peer refuses.
      final device = await AxolotlDevice.generateNewDevice(
        'me@example.org',
        preKeyCount: 2,
      );
      final bundle = await device.toBundle();
      final bare = (bundle.signedPreKeyPublic as DjbECPublicKey).publicKey;

      expect(bare, hasLength(32));
      expect(
        Curve.verifySignature(
          bundle.identityKey.publicKey,
          bare,
          bundle.signedPreKeySignature,
        ),
        isFalse,
        reason: 'the signed message is the 33-byte serialization',
      );
    });

    test('every published key carries the type byte', () async {
      final device = await AxolotlDevice.generateNewDevice(
        'me@example.org',
        preKeyCount: 3,
      );
      final bundle = await device.toBundle();

      for (final entry in bundle.preKeysEncoded.entries) {
        final decoded = Curve.decodePoint(decodeBase64(entry.value), 0);
        expect(
          decoded.serialize().first,
          Curve.djbType,
          reason: 'prekey ${entry.key} must be serialized',
        );
        expect(decoded.serialize(), hasLength(33));
      }
    });
  });
}

/// base64 decode into the Uint8List libsignal's API wants.
Uint8List decodeBase64(String value) => Uint8List.fromList(base64Decode(value));
