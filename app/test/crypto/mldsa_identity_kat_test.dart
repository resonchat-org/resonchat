// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Offline, CI-enforced known-answer test for the OMEMO2 PQ identity
// (ML-DSA-87, FIPS 204). It covers the two-way boundary that the other
// unit tests do not:
//
//   pure-Dart sign (pqcrypto `MlDsa`, i.e. production `PqIdentityStore.sign`)
//        -> native verify (libsignal/libcrux `PqIdentityKey.verify`)
//   native sign (libsignal `PqIdentityKeyPair.sign`)
//        -> pure-Dart verify (pqcrypto `MlDsa.verify` / `PqIdentityStore.verify`)
//
// `integration_test/b_track_interop_test.dart` exercises the same boundary
// end to end, but it needs a real account/network, is not run by CI, and its
// PQ assertions live under `if (pqSendable)` so they can silently SKIP.
// This file is deterministic (seeded keygen + deterministic signing),
// offline, and runs under `flutter test`, so CI fails if either standalone
// implementation drifts from the other.

import 'dart:convert';
import 'dart:typed_data';

// `pqBundleTranscript` also exists in the libsignal bindings (a different
// helper); we test the ResonChat one from omemo2_transcript.dart.
import 'package:libsignal/libsignal.dart' hide pqBundleTranscript;
import 'package:omemo_dart/omemo_dart_omemo2.dart' show omemo2EnsureLibSignal;
import 'package:pqcrypto/pqcrypto.dart';
import 'package:resonchat/crypto/omemo/omemo2_transcript.dart';
import 'package:resonchat/crypto/omemo/protocol.dart';
import 'package:resonchat/crypto/pq_identity_store.dart';
import 'package:test/test.dart';

/// FIPS 204 domain-separation context used by production signing
/// (`PqIdentityStore.sign` / native `pqid.rs`). Must round-trip unchanged.
final _ctx = Uint8List.fromList(utf8.encode(omemo2PqIdContext));

/// Fixed keygen seed: every run signs the exact same bytes, so a failure is a
/// real regression rather than CSPRNG noise.
final _seed = Uint8List.fromList(List<int>.generate(32, (i) => i));

/// A production-shaped signed transcript: fixed identity keys + KEM binding,
/// run through the same `pqBundleTranscript` the bundle codec uses.
Uint8List _transcript(Uint8List pqIk) {
  final ik = Uint8List.fromList([
    0x05,
    ...List<int>.generate(32, (i) => 0x40 + i),
  ]);
  final spk = Uint8List.fromList([
    0x05,
    ...List<int>.generate(32, (i) => 0x80 + i),
  ]);
  final kemBindingDigest = Uint8List.fromList(List<int>.generate(64, (i) => i));
  return pqBundleTranscript(
    ik: ik,
    pqIk: pqIk,
    signedPreKeyId: 7,
    spk: spk,
    kemBindingDigest: kemBindingDigest,
  );
}

void main() {
  setUpAll(omemo2EnsureLibSignal);

  group('ML-DSA-87 identity KAT (pure Dart pqcrypto <-> native libsignal)', () {
    late (Uint8List, Uint8List) pair; // (pk, sk)
    late Uint8List message;

    setUp(() {
      pair = MlDsa.generateKeyPairSeeded(DilithiumParams.mlDsa87, _seed);
      message = _transcript(pair.$1);
    });

    test('pure-Dart sign -> native verify', () {
      final (pk, sk) = pair;
      final sig = MlDsa.signDeterministic(
        sk,
        message,
        DilithiumParams.mlDsa87,
        ctx: _ctx,
      );
      expect(pk.length, 2592);
      expect(sig.length, 4627);

      final nativeKey = PqIdentityKey.deserialize(bytes: pk);
      expect(
        nativeKey.verify(
          message: message,
          signature: PqSignature.deserialize(bytes: sig),
        ),
        isTrue,
        reason: 'libsignal must accept a pqcrypto ML-DSA-87 signature',
      );

      // A tampered transcript must not verify.
      final tampered = Uint8List.fromList(message)..[0] ^= 0xFF;
      expect(
        nativeKey.verify(
          message: tampered,
          signature: PqSignature.deserialize(bytes: sig),
        ),
        isFalse,
      );
    });

    test('native sign -> pure-Dart verify', () {
      final native = PqIdentityKeyPair.generate();
      final pk = native.publicKey().serialize();
      final sig = native.sign(message: message).serialize();

      expect(
        MlDsa.verify(pk, message, sig, DilithiumParams.mlDsa87, ctx: _ctx),
        isTrue,
        reason: 'pqcrypto must accept a libsignal ML-DSA-87 signature',
      );
      // Same call the production Dart-side helper makes.
      expect(
        PqIdentityStore.verify(publicKey: pk, message: message, signature: sig),
        isTrue,
      );

      final tampered = Uint8List.fromList(message)..[0] ^= 0xFF;
      expect(
        MlDsa.verify(pk, tampered, sig, DilithiumParams.mlDsa87, ctx: _ctx),
        isFalse,
      );
    });

    test('seeded keygen is reproducible', () {
      final again = MlDsa.generateKeyPairSeeded(DilithiumParams.mlDsa87, _seed);
      expect(again.$1, pair.$1);
      expect(again.$2, pair.$2);
    });

    test('deterministic signing is stable', () {
      final (_, sk) = pair;
      final a = MlDsa.signDeterministic(
        sk,
        message,
        DilithiumParams.mlDsa87,
        ctx: _ctx,
      );
      final b = MlDsa.signDeterministic(
        sk,
        message,
        DilithiumParams.mlDsa87,
        ctx: _ctx,
      );
      expect(a, b);
    });

    test('context is load-bearing on both sides', () {
      // Produced under `omemo2PqIdContext`; verifying under the empty
      // FIPS 204 context must fail. This is what proves both implementations
      // fold the same domain-separation string into M'.
      final (pk, sk) = pair;
      final sig = MlDsa.signDeterministic(
        sk,
        message,
        DilithiumParams.mlDsa87,
        ctx: _ctx,
      );
      expect(MlDsa.verify(pk, message, sig, DilithiumParams.mlDsa87), isFalse);
    });
  });
}
