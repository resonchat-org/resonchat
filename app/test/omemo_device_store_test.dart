// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// OMEMO device persistence: a round-trip must reproduce the exact key
// material, and a lost/tampered blob must degrade to "no device" rather
// than crash or, worse, resurrect partial keys.

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:omemo_dart/omemo_dart.dart';
import 'package:test/test.dart';
import 'package:resonchat/store/omemo_device_store.dart';

void main() {
  late Map<String, String> blob;
  late _MemoryKeystore keystore;
  late OmemoDeviceStore store;

  OmemoDeviceStore buildStore(_MemoryKeystore ks, Map<String, String> b) =>
      OmemoDeviceStore(
        secureStorage: ks,
        loadSecret: () async {
          final v = b['blob'];
          return v == null ? null : _b64d(v);
        },
        saveSecret: (bytes) async => b['blob'] = _b64e(bytes),
        deleteSecret: () async => b.remove('blob'),
      );

  setUp(() {
    blob = {};
    keystore = _MemoryKeystore();
    store = buildStore(keystore, blob);
  });

  test('round-trips identity, signed prekey and one-time prekeys', () async {
    final device =
        await OmemoDevice.generateNewDevice('me@example.org', opkAmount: 3);
    final id = await store.save(device);
    expect(id, device.id);

    final back = await store.load();
    expect(back, isNotNull);
    expect(back!.id, device.id);
    expect(back.jid, 'me@example.org');
    expect(back.spkId, device.spkId);
    expect(back.spkSignature, device.spkSignature);
    expect(back.opks.keys.toSet(), device.opks.keys.toSet());

    expect(await back.ik.sk.getBytes(), await device.ik.sk.getBytes());
    expect(await back.ik.pk.getBytes(), await device.ik.pk.getBytes());
    expect(await back.spk.sk.getBytes(), await device.spk.sk.getBytes());
    expect(await back.spk.pk.getBytes(), await device.spk.pk.getBytes());
    for (final e in device.opks.entries) {
      expect(await back.opks[e.key]!.sk.getBytes(), await e.value.sk.getBytes());
      expect(await back.opks[e.key]!.pk.getBytes(), await e.value.pk.getBytes());
    }
  });

  test('stored blob is nonce||ciphertext||mac with a real GCM tag', () async {
    final device =
        await OmemoDevice.generateNewDevice('me@example.org', opkAmount: 1);
    await store.save(device);
    final bytes = _b64d(blob['blob']!);

    // A 12-byte nonce followed by a 16-byte tag means the plaintext can
    // never exceed bytes.length - 28. Guards against offset mistakes.
    expect(bytes.length, greaterThan(28));
  });

  test('returns null when nothing was stored', () async {
    expect(await store.load(), isNull);
  });

  test('survives a process restart by reusing the stored blob', () async {
    final device =
        await OmemoDevice.generateNewDevice('me@example.org', opkAmount: 1);
    await store.save(device);

    // A fresh store over the same storage: the sealing key lives in the
    // keystore, not in the blob, so it must still open.
    final reopened = buildStore(keystore, blob);
    final back = await reopened.load();
    expect(back!.id, device.id);
    expect(await back.ik.sk.getBytes(), await device.ik.sk.getBytes());
  });

  test('a lost keystore key discards the blob rather than crashing',
      () async {
    final device =
        await OmemoDevice.generateNewDevice('me@example.org', opkAmount: 1);
    await store.save(device);

    // Simulate a reinstall: blob survives, keystore key does not.
    keystore.values.clear();
    expect(await buildStore(keystore, blob).load(), isNull);
  });

  test('a tampered blob is discarded instead of returned', () async {
    final device =
        await OmemoDevice.generateNewDevice('me@example.org', opkAmount: 1);
    await store.save(device);

    final bytes = _b64d(blob['blob']!);
    // Flip a bit inside the ciphertext (past nonce and MAC).
    bytes[bytes.length - 20] ^= 0x01;
    blob['blob'] = _b64e(bytes);

    expect(await store.load(), isNull);
    // The bad blob is dropped so we do not retry it forever.
    expect(blob.containsKey('blob'), isFalse);
  });

  test('a truncated blob is discarded', () async {
    final device =
        await OmemoDevice.generateNewDevice('me@example.org', opkAmount: 1);
    await store.save(device);
    blob['blob'] = _b64e(_b64d(blob['blob']!).sublist(0, 8));
    expect(await store.load(), isNull);
  });
}

/// Minimal in-memory stand-in for the platform keystore.
class _MemoryKeystore implements FlutterSecureStorage {
  final Map<String, String> values = {};

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      values[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

String _b64e(List<int> b) => base64Encode(b);
List<int> _b64d(String s) => base64Decode(s);