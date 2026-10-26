// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:resonchat/translate/libretranslate_engine.dart';
import 'package:resonchat/translate/translatable_text.dart';

void main() {
  test('isTranslatableText skips empty and emoji-only', () {
    expect(isTranslatableText(''), isFalse);
    expect(isTranslatableText('   '), isFalse);
    expect(isTranslatableText('😀👍'), isFalse);
    expect(isTranslatableText('Hello'), isTrue);
    expect(isTranslatableText('你好'), isTrue);
    expect(isTranslatableText('ok 😀'), isTrue);
  });

  test('canOfferTranslate skips media and undecrypted', () {
    expect(
      canOfferTranslate(
        body: 'Hello',
        decrypted: true,
        retracted: false,
        hasMedia: false,
      ),
      isTrue,
    );
    expect(
      canOfferTranslate(
        body: 'Hello',
        decrypted: true,
        retracted: false,
        hasMedia: true,
      ),
      isFalse,
    );
    expect(
      canOfferTranslate(
        body: 'Hello',
        decrypted: false,
        retracted: false,
        hasMedia: false,
      ),
      isFalse,
    );
  });

  test('LibreTranslateEngine posts JSON and reads translatedText', () async {
    final client = MockClient((request) async {
      expect(request.url.toString(), 'http://127.0.0.1:5000/translate');
      expect(request.method, 'POST');
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['q'], 'Hello');
      expect(body['source'], 'auto');
      expect(body['target'], 'zh');
      return http.Response(
        jsonEncode({'translatedText': '你好'}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final engine = LibreTranslateEngine(
      baseUrl: 'http://127.0.0.1:5000/',
      client: client,
    );
    final result = await engine.translate(text: 'Hello', targetLang: 'zh');
    expect(result.text, '你好');
  });
}
