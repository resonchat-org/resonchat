// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:resonchat/translate/deepl_engine.dart';

void main() {
  test('DeepLEngine posts JSON and reads translations[0].text', () async {
    final client = MockClient((request) async {
      expect(request.url.host, 'api-free.deepl.com');
      expect(request.url.path, '/v2/translate');
      expect(request.headers['Authorization'], 'DeepL-Auth-Key test-key');
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['text'], ['Hello']);
      expect(body['target_lang'], 'ZH');
      return http.Response(
        jsonEncode({
          'translations': [
            {'detected_source_language': 'EN', 'text': '你好'},
          ],
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final engine = DeepLEngine(apiKey: 'test-key', client: client);
    final result = await engine.translate(text: 'Hello', targetLang: 'zh');
    expect(result.text, '你好');
    expect(result.detectedSource, 'EN');
  });

  test('normalizeTarget uppercases and strips region', () {
    expect(DeepLEngine.normalizeTarget('zh'), 'ZH');
    expect(DeepLEngine.normalizeTarget('en-US'), 'EN');
  });
}
