// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// OMEMO device persistence (M5 groundwork).
//
// omemo_dart has no serialization for OmemoDevice, so we persist the
// raw key material ourselves and rebuild the device on startup. Without
// this, every app start would register a new device id and slowly
// pollute our own PEP device list.
//
// Key material never goes to the database in the clear: it is sealed
// with AES-GCM under a 256-bit key held in the platform keystore
// (Android Keystore / iOS Keychain), which is what M5 needs anyway.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:omemo_dart/omemo_dart.dart';

/// Sealed OMEMO device blob, stored as a single JSON column.
class OmemoDeviceStore {
  OmemoDeviceStore({
    required this.loadSecret,
    required this.saveSecret,
    required this.deleteSecret,
    FlutterSecureStorage? secureStorage,
  }) : _secure = secureStorage;

  /// Where the sealed blob lives (a `meta`-style row in the database).
  final Future<List<int>?> Function() loadSecret;
  final Future<void> Function(List<int> bytes) saveSecret;
  final Future<void> Function() deleteSecret;

  final FlutterSecureStorage? _secure;

  static const _keystoreKey = 'resonchat.device.sealing-key';

  late final AesGcm _cipher = AesGcm.with256bits();

  /// Returns the platform keystore key, generating one on first use.
  Future<List<int>> _sealingKey() async {
    final secure = _secure;
    if (secure == null) {
      // No keystore available (e.g. unit tests): caller supplies its own.
      throw StateError('no secure storage configured');
    }
    final existing = await secure.read(key: _keystoreKey);
    if (existing != null) return base64Decode(existing);
    final fresh = _randomBytes(32);
    await secure.write(key: _keystoreKey, value: base64Encode(fresh));
    return fresh;
  }

  /// Serializes [device] and stores it sealed. Returns the device id.
  Future<int> save(OmemoDevice device) async {
    final json = jsonEncode({
      'jid': device.jid,
      'id': device.id,
      'ik': base64Encode(await device.ik.sk.getBytes()),
      'ikPub': base64Encode(await device.ik.pk.getBytes()),
      'spk': base64Encode(await device.spk.sk.getBytes()),
      'spkPub': base64Encode(await device.spk.pk.getBytes()),
      'spkId': device.spkId,
      'spkSig': base64Encode(device.spkSignature),
      'opks': {
        for (final e in device.opks.entries)
          '${e.key}': base64Encode(await e.value.sk.getBytes()),
        for (final e in device.opks.entries)
          '${e.key}p': base64Encode(await e.value.pk.getBytes()),
      },
    });
    final key = SecretKey(await _sealingKey());
    final nonce = _randomBytes(12);
    final sealed = await _cipher.encrypt(
      utf8.encode(json),
      secretKey: key,
      nonce: nonce,
    );
    // `concatenation()` lays out nonce || ciphertext || mac.
    final packed = sealed.concatenation();
    await saveSecret(packed);
    return device.id;
  }

  /// Rebuilds the device previously written by [save], or null when there
  /// is none or the blob cannot be opened (e.g. keystore reset after a
  /// reinstall — in that case the caller must generate a new device).
  Future<OmemoDevice?> load() async {
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
      final opks = <int, OmemoKeyPair>{};
      final rawOpks = map['opks'] as Map<String, dynamic>;
      for (final entry in rawOpks.entries) {
        if (entry.key.endsWith('p')) continue;
        final id = int.parse(entry.key);
        opks[id] = OmemoKeyPair.fromBytes(
          base64Decode(rawOpks['${id}p'] as String),
          base64Decode(entry.value as String),
          KeyPairType.x25519,
        );
      }
      return OmemoDevice(
        map['jid'] as String,
        map['id'] as int,
        OmemoKeyPair.fromBytes(
          base64Decode(map['ikPub'] as String),
          base64Decode(map['ik'] as String),
          KeyPairType.ed25519,
        ),
        OmemoKeyPair.fromBytes(
          base64Decode(map['spkPub'] as String),
          base64Decode(map['spk'] as String),
          KeyPairType.x25519,
        ),
        map['spkId'] as int,
        base64Decode(map['spkSig'] as String),
        null,
        null,
        opks,
      );
    } catch (_) {
      // Sealing key lost or blob corrupted: treat as "no device".
      await deleteSecret();
      return null;
    }
  }
}

/// Cryptographically secure random bytes from the platform CSPRNG.
/// Key material must never come from anything weaker.
List<int> _randomBytes(int n) =>
    Uint8List.fromList(List<int>.generate(n, (_) => _rng.nextInt(256)));

final Random _rng = Random.secure();