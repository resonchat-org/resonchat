// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// LibreTranslate-compatible HTTP API (self-hosted).

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:resonchat/translate/translation_engine.dart';

class LibreTranslateEngine implements TranslationEngine {
  LibreTranslateEngine({required this.baseUrl, this.apiKey = '', this.client});

  final String baseUrl;
  final String apiKey;
  final http.Client? client;

  @override
  TranslationEngineId get id => TranslationEngineId.libreTranslate;

  Uri _uri(String path) {
    final root = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (root.isEmpty) {
      throw StateError('LibreTranslate base URL is not configured');
    }
    return Uri.parse('$root$path');
  }

  @override
  Future<TranslationResult> translate({
    required String text,
    required String targetLang,
    String sourceLang = 'auto',
  }) async {
    final body = <String, dynamic>{
      'q': text,
      'source': sourceLang.isEmpty ? 'auto' : sourceLang,
      'target': targetLang,
      'format': 'text',
    };
    if (apiKey.trim().isNotEmpty) {
      body['api_key'] = apiKey.trim();
    }

    final httpClient = client ?? http.Client();
    final owned = client == null;
    try {
      final resp = await httpClient.post(
        _uri('/translate'),
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode(body),
      );
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw StateError(
          'LibreTranslate HTTP ${resp.statusCode}: ${resp.body}',
        );
      }
      final json = jsonDecode(resp.body);
      if (json is! Map) {
        throw StateError('LibreTranslate: unexpected response');
      }
      final translated = json['translatedText']?.toString() ?? '';
      if (translated.isEmpty) {
        throw StateError('LibreTranslate: empty translation');
      }
      String? detected;
      final det = json['detectedLanguage'];
      if (det is Map && det['language'] != null) {
        detected = det['language'].toString();
      }
      return TranslationResult(text: translated, detectedSource: detected);
    } finally {
      if (owned) httpClient.close();
    }
  }

  @override
  Future<void> testConnection({required String targetLang}) async {
    await translate(text: 'Hello', targetLang: targetLang);
  }
}
