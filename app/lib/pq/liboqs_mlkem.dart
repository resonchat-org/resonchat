// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

/// Minimal C ABI exported by the native bridge.
///
/// Only the operations PQ-OMEMO needs: ML-KEM-768 key generation,
/// encapsulation and decapsulation. Every function returns 0 on success
/// and a negative value on failure, and writes into caller-provided
/// buffers so Dart owns the memory (see `pq_bridge.c`).
///
/// Buffer sizes are fixed by FIPS 203 and must match [MlKem768].
library;

import 'dart:ffi';
import 'dart:typed_data';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'mlkem.dart';
import 'pqcrypto_mlkem.dart';

/// Signature of `int pq_mlkem768_keypair(uint8_t* pk, uint8_t* sk)`.
typedef _KeypairNative = Int32 Function(Pointer<Uint8>, Pointer<Uint8>);

/// `int pq_mlkem768_encaps(const uint8_t* pk, uint8_t* ct, uint8_t* ss)`
typedef _EncapsNative = Int32 Function(
  Pointer<Uint8>,
  Pointer<Uint8>,
  Pointer<Uint8>,
);

/// `int pq_mlkem768_decaps(const uint8_t* sk, const uint8_t* ct, uint8_t* ss)`
typedef _DecapsNative = Int32 Function(
  Pointer<Uint8>,
  Pointer<Uint8>,
  Pointer<Uint8>,
);

/// ML-KEM-768 backed by liboqs.
///
/// Preferred over the pure-Dart backend on Android (hardware-accelerated,
/// constant-time native code) and required for FIPS-validated builds.
/// Falls back to [PqcryptoMlKem768] elsewhere; see `MlKem768Provider`.
class LiboqsMlKem768 implements MlKem768 {
  LiboqsMlKem768._(DynamicLibrary lib)
      : _keypair = lib.lookupFunction<_KeypairNative,
            int Function(Pointer<Uint8>, Pointer<Uint8>)>('pq_mlkem768_keypair'),
        _encaps = lib.lookupFunction<_EncapsNative,
            int Function(Pointer<Uint8>, Pointer<Uint8>,
                Pointer<Uint8>)>('pq_mlkem768_encaps'),
        _decaps = lib.lookupFunction<_DecapsNative,
            int Function(Pointer<Uint8>, Pointer<Uint8>,
                Pointer<Uint8>)>('pq_mlkem768_decaps');

  /// Opens the bridge, or returns null when it is unavailable on this
  /// platform (desktop, tests, web).
  static LiboqsMlKem768? tryLoad() {
    if (!Platform.isAndroid && !Platform.isIOS) return null;
    final failures = <String>[];
    for (final name in const ['libpqbridge.so', 'libpqbridge.dylib']) {
      try {
        return LiboqsMlKem768._(DynamicLibrary.open(name));
      } catch (e) {
        // Any failure (missing .so, stripped symbols) must fall back
        // silently; keep every reason for diagnostics.
        failures.add('$name: $e');
      }
    }
    loadError = failures.join(' | ');
    return null;
  }

  /// Why the native backend was unavailable, or null if it loaded.
  /// Surfaced on the settings page so a packaging mistake is visible
  /// rather than silently degrading to pure Dart.
  static String? loadError;

  final int Function(Pointer<Uint8>, Pointer<Uint8>) _keypair;
  final int Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>) _encaps;
  final int Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>) _decaps;

  @override
  KemKeyPair generateKeyPair() {
    final pk = calloc<Uint8>(MlKem768.publicKeyLength);
    final sk = calloc<Uint8>(MlKem768.secretKeyLength);
    try {
      final rc = _keypair(pk, sk);
      if (rc != 0) throw StateError('pq_mlkem768_keypair failed: $rc');
      // Copy out before freeing: a Uint8List view would dangle.
      return KemKeyPair(
        publicKey: Uint8List.fromList(pk.asTypedList(MlKem768.publicKeyLength)),
        secretKey: Uint8List.fromList(sk.asTypedList(MlKem768.secretKeyLength)),
      );
    } finally {
      calloc.free(pk);
      calloc.free(sk);
    }
  }

  @override
  KemEncapsulation encapsulate(List<int> publicKey) {
    final pk = calloc<Uint8>(MlKem768.publicKeyLength);
    pk.asTypedList(MlKem768.publicKeyLength).setAll(0, publicKey);
    final ct = calloc<Uint8>(MlKem768.ciphertextLength);
    final ss = calloc<Uint8>(MlKem768.sharedSecretLength);
    try {
      final rc = _encaps(pk, ct, ss);
      if (rc != 0) throw StateError('pq_mlkem768_encaps failed: $rc');
      return KemEncapsulation(
        ciphertext:
            Uint8List.fromList(ct.asTypedList(MlKem768.ciphertextLength)),
        sharedSecret:
            Uint8List.fromList(ss.asTypedList(MlKem768.sharedSecretLength)),
      );
    } finally {
      calloc.free(pk);
      calloc.free(ct);
      calloc.free(ss);
    }
  }

  @override
  List<int> decapsulate(List<int> secretKey, List<int> ciphertext) {
    final sk = calloc<Uint8>(MlKem768.secretKeyLength);
    sk.asTypedList(MlKem768.secretKeyLength).setAll(0, secretKey);
    final ct = calloc<Uint8>(MlKem768.ciphertextLength);
    ct.asTypedList(MlKem768.ciphertextLength).setAll(0, ciphertext);
    final ss = calloc<Uint8>(MlKem768.sharedSecretLength);
    try {
      final rc = _decaps(sk, ct, ss);
      if (rc != 0) throw StateError('pq_mlkem768_decaps failed: $rc');
      return Uint8List.fromList(
        ss.asTypedList(MlKem768.sharedSecretLength),
      );
    } finally {
      calloc.free(sk);
      calloc.free(ct);
      calloc.free(ss);
    }
  }
}

/// Chooses the best available ML-KEM-768 backend once per process.
///
/// Android gets liboqs; everything else (desktop, tests, web) keeps the
/// pure-Dart path, which is correct everywhere but slower. Both are
/// proven equivalent in `test/mlkem_interop_test.dart`.
class MlKem768Provider {
  MlKem768Provider._(this._kem);

  static MlKem768Provider get instance => _instance ??= _resolve();
  static MlKem768Provider? _instance;

  static MlKem768Provider _resolve() {
    final native = LiboqsMlKem768.tryLoad();
    return MlKem768Provider._(native ?? PqcryptoMlKem768());
  }

  final MlKem768 _kem;

  /// The active implementation.
  MlKem768 get kem => _kem;

  /// True when the native liboqs backend is in use.
  bool get isNative => _kem is LiboqsMlKem768;
}