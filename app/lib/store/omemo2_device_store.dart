// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sealed OMEMO2 (PQ) device blob — same wrapping pattern as [OmemoDeviceStore].
// Without this, every connect minted a new classical IK and the hybrid
// fingerprint drifted from what peers had pinned.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:omemo_dart/omemo_dart_omemo2.dart';

/// Sealed OMEMO2 device snapshot (classical IK + ML-KEM material).
class Omemo2DeviceStore {
  Omemo2DeviceStore({
    required this.accountId,
    required this.loadSecret,
    required this.saveSecret,
    required this.deleteSecret,
    FlutterSecureStorage? secureStorage,
  }) : _secure = secureStorage ?? const FlutterSecureStorage();

  final String accountId;
  final Future<List<int>?> Function() loadSecret;
  final Future<void> Function(List<int> bytes) saveSecret;
  final Future<void> Function() deleteSecret;
  final FlutterSecureStorage _secure;

  /// Same epoch policy as [OmemoDeviceStore]: mismatch → discard, no migrate.
  static const _formatVersion = 1;

  late final AesGcm _cipher = AesGcm.with256bits();

  String get _sealingKeyName =>
      'resonchat.omemo2.device.sealing-key.v$_formatVersion.$accountId';

  Future<List<int>> _sealingKey() async {
    final existing = await _secure.read(key: _sealingKeyName);
    if (existing != null) return base64Decode(existing);
    final fresh = _randomBytes(32);
    await _secure.write(key: _sealingKeyName, value: base64Encode(fresh));
    return fresh;
  }

  Future<void> save(Omemo2Device device) async {
    final snap = await device.snapshot();
    final json = jsonEncode({'v': _formatVersion, ...snap.toJson()});
    final key = SecretKey(await _sealingKey());
    final nonce = _randomBytes(12);
    final sealed = await _cipher.encrypt(
      utf8.encode(json),
      secretKey: key,
      nonce: nonce,
    );
    await saveSecret(sealed.concatenation());
  }

  Future<void> clear() => deleteSecret();

  Future<Omemo2Device?> load() async {
    final packed = await loadSecret();
    if (packed == null || packed.length < 12 + 16 + 1) return null;

    final key = SecretKey(await _sealingKey());
    try {
      final opened = await _cipher.decrypt(
        SecretBox.fromConcatenation(
          packed,
          nonceLength: _cipher.nonceLength,
          macLength: _cipher.macAlgorithm.macLength,
        ),
        secretKey: key,
      );
      final map = jsonDecode(utf8.decode(opened)) as Map<String, dynamic>;
      if (map['v'] != _formatVersion) {
        await deleteSecret();
        return null;
      }
      return await Omemo2Device.fromSnapshot(
        Omemo2DeviceSnapshot.fromJson(map),
      );
    } catch (_) {
      await deleteSecret();
      return null;
    }
  }
}

List<int> _randomBytes(int n) =>
    Uint8List.fromList(List<int>.generate(n, (_) => _rng.nextInt(256)));

final Random _rng = Random.secure();
