// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hex/hex.dart';

import 'package:resonchat/xmpp/media/aesgcm_url.dart';

void main() {
  group('AesGcmUrl', () {
    test('toAesGcmUrl matches Conversations scheme swap', () {
      final keyIv = Uint8List.fromList(List<int>.filled(44, 0xab));
      final url = AesGcmUrl.toAesGcmUrl(
        'https://upload.example/file/abc',
        keyIv,
      );
      expect(url.startsWith('aesgcm://upload.example/file/abc#'), isTrue);
      expect(url.split('#').last, HEX.encode(keyIv));
      expect(AesGcmUrl.isAesGcm(url), isTrue);
      expect(
        AesGcmUrl.httpsUri(url).toString(),
        'https://upload.example/file/abc',
      );
    });

    test('encrypt/decrypt round-trip (44-byte IV+key)', () async {
      final keyIv = AesGcmUrl.newKeyAndIv();
      expect(keyIv.length, 44);
      final clear = Uint8List.fromList('hello file'.codeUnits);
      final cipher = await AesGcmFileCrypto.encrypt(clear, keyIv);
      expect(cipher.length, clear.length + 16);
      final frag = HEX.encode(keyIv);
      final out = await AesGcmFileCrypto.decrypt(cipher, frag);
      expect(out, clear);
    });
  });
}
