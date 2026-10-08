// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Axolotl (OMEMO 0.3.0) device persistence.
//
// Key material never goes to the database in the clear: it is sealed
// with AES-GCM under a 256-bit key held in the platform keystore.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:omemo_dart/omemo_dart_axolotl.dart';

/// Sealed axolotl device blob, stored as a single JSON column.
class OmemoDeviceStore {
  OmemoDeviceStore({
    required this.loadSecret,
    required this.saveSecret,
    required this.deleteSecret,
    FlutterSecureStorage? secureStorage,
  }) : _secure = secureStorage;

  final Future<List<int>?> Function() loadSecret;
  final Future<void> Function(List<int> bytes) saveSecret;
  final Future<void> Function() deleteSecret;

  final FlutterSecureStorage? _secure;

  static const _keystoreKey = 'resonchat.device.sealing-key';
  static const _formatVersion = 2; // axolotl snapshot

  late final AesGcm _cipher = AesGcm.with256bits();

  Future<List<int>> _sealingKey() async {
    final secure = _secure;
    if (secure == null) {
      throw StateError('no secure storage configured');
    }
    final existing = await secure.read(key: _keystoreKey);
    if (existing != null) return base64Decode(existing);
    final fresh = _randomBytes(32);
    await secure.write(key: _keystoreKey, value: base64Encode(fresh));
    return fresh;
  }

  /// Serializes [device] and stores it sealed. Returns the device id.
  Future<int> save(AxolotlDevice device) async {
    final preKeyIds = device.store.preKeyStore.store.keys.toList();
    final snap = await device.snapshot(preKeyIds);
    final json = jsonEncode({'v': _formatVersion, ...snap.toJson()});
    final key = SecretKey(await _sealingKey());
    final nonce = _randomBytes(12);
    final sealed = await _cipher.encrypt(
      utf8.encode(json),
      secretKey: key,
      nonce: nonce,
    );
    await saveSecret(sealed.concatenation());
    return await device.deviceId;
  }

  /// Rebuilds the device previously written by [save], or null when there
  /// is none, the blob is a legacy classic-OMEMO format, or it cannot be opened.
  Future<AxolotlDevice?> load() async {
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
        // Legacy classic OmemoDevice blob — force regeneration.
        await deleteSecret();
        return null;
      }
      return await AxolotlDevice.fromSnapshot(
        AxolotlDeviceSnapshot.fromJson(map),
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
