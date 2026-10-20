// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// ML-DSA-87 post-quantum identity for monocles OMEMO2 (`pq-ik` / `pq-sig`).

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:omemo_dart/omemo_dart_omemo2.dart' show omemo2PqIdContext;
import 'package:pqcrypto/pqcrypto.dart';

/// Lazily generates and persists an ML-DSA-87 key pair per account
/// (monocles `AxolotlService.getOwnPqIdentityKeyPair`).
class PqIdentityStore {
  PqIdentityStore({required this.accountId, FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final String accountId;
  final FlutterSecureStorage _storage;

  static const _formatVersion = 1;

  String get _storageKey => 'resonchat.omemo2.pq-identity.$accountId';

  /// Public key bytes (2592) for hybrid fingerprint and `<pq-ik>`.
  Future<Uint8List> publicKey() async {
    final pair = await keyPair();
    return pair.$1;
  }

  /// `(pk, sk)` for signing the OMEMO2 bundle transcript.
  Future<(Uint8List, Uint8List)> keyPair() => _loadOrGenerate();

  /// ML-DSA-87 signature over [message] with FIPS-204 context
  /// [omemo2PqIdContext].
  Future<Uint8List> sign(Uint8List message) async {
    final (_, sk) = await keyPair();
    return MlDsa.sign(
      sk,
      message,
      DilithiumParams.mlDsa87,
      ctx: Uint8List.fromList(utf8.encode(omemo2PqIdContext)),
    );
  }

  /// Verify [signature] over [message] under [publicKey].
  static bool verify({
    required Uint8List publicKey,
    required Uint8List message,
    required Uint8List signature,
  }) {
    return MlDsa.verify(
      publicKey,
      message,
      signature,
      DilithiumParams.mlDsa87,
      ctx: Uint8List.fromList(utf8.encode(omemo2PqIdContext)),
    );
  }

  /// Drop the pair so the next load regenerates (after OMEMO2 wipe).
  Future<void> clear() => _storage.delete(key: _storageKey);

  Future<(Uint8List, Uint8List)> _loadOrGenerate() async {
    final existing = await _storage.read(key: _storageKey);
    if (existing != null) {
      try {
        final map = jsonDecode(existing) as Map<String, dynamic>;
        if (map['v'] == _formatVersion) {
          final pk = base64Decode(map['pk'] as String);
          final sk = base64Decode(map['sk'] as String);
          if (pk.length == DilithiumParams.mlDsa87.publicKeyBytes &&
              sk.length == DilithiumParams.mlDsa87.secretKeyBytes) {
            return (Uint8List.fromList(pk), Uint8List.fromList(sk));
          }
        }
      } catch (_) {
        // Fall through and regenerate.
      }
    }
    final (pk, sk) = MlDsa.generateKeyPair(DilithiumParams.mlDsa87);
    await _storage.write(
      key: _storageKey,
      value: jsonEncode({
        'v': _formatVersion,
        'pk': base64Encode(pk),
        'sk': base64Encode(sk),
      }),
    );
    return (pk, sk);
  }
}
