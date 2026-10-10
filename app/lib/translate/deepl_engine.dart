// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'translation_engine.dart';

class DeepLEngine implements TranslationEngine {
  DeepLEngine({required this.apiKey, this.pro = false, this.client});

  final String apiKey;
  final bool pro;
  final http.Client? client;

  @override
  TranslationEngineId get id => TranslationEngineId.deepL;

  Uri get _translateUri => Uri.parse(
    pro
        ? 'https://api.deepl.com/v2/translate'
        : 'https://api-free.deepl.com/v2/translate',
  );

  /// DeepL wants uppercase ISO codes (`ZH`, `EN`); drop regional tags.
  static String normalizeTarget(String uiLang) {
    final base = uiLang.split(RegExp(r'[-_]')).first.toUpperCase();
    return base;
  }

  @override
  Future<TranslationResult> translate({
    required String text,
    required String targetLang,
    String sourceLang = 'auto',
  }) async {
    final key = apiKey.trim();
    if (key.isEmpty) {
      throw StateError('DeepL API key is not configured');
    }
    final body = <String, dynamic>{
      'text': [text],
      'target_lang': normalizeTarget(targetLang),
    };
    if (sourceLang.isNotEmpty && sourceLang != 'auto') {
      body['source_lang'] = normalizeTarget(sourceLang);
    }

    final httpClient = client ?? http.Client();
    final owned = client == null;
    try {
      final resp = await httpClient.post(
        _translateUri,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'DeepL-Auth-Key $key',
        },
        body: jsonEncode(body),
      );
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw StateError('DeepL HTTP ${resp.statusCode}: ${resp.body}');
      }
      final json = jsonDecode(resp.body);
      if (json is! Map) throw StateError('DeepL: unexpected response');
      final list = json['translations'];
      if (list is! List || list.isEmpty) {
        throw StateError('DeepL: empty translations');
      }
      final first = list.first;
      if (first is! Map) throw StateError('DeepL: bad translation entry');
      final out = first['text']?.toString() ?? '';
      if (out.isEmpty) throw StateError('DeepL: empty text');
      return TranslationResult(
        text: out,
        detectedSource: first['detected_source_language']?.toString(),
      );
    } finally {
      if (owned) httpClient.close();
    }
  }

  @override
  Future<void> testConnection({required String targetLang}) async {
    await translate(text: 'Hello', targetLang: targetLang);
  }
}
