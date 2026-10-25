// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:http/http.dart' as http;

import 'package:resonchat/net/app_network.dart';
import 'package:resonchat/translate/deepl_engine.dart';
import 'package:resonchat/translate/libretranslate_engine.dart';
import 'package:resonchat/translate/offline_translator_engine.dart';
import 'package:resonchat/translate/translation_engine.dart';
import 'package:resonchat/translate/translation_prefs.dart';

/// Builds an engine from prefs and runs translate / test.
class TranslationService {
  TranslationService({http.Client Function()? clientFactory})
    : _clientFactory = clientFactory ?? appNetwork.createHttpClient;

  final http.Client Function() _clientFactory;

  /// Whether prefs look usable enough to attempt a request.
  bool isConfigured(TranslationPrefs prefs) {
    return switch (prefs.engine) {
      TranslationEngineId.libreTranslate => prefs.baseUrl.trim().isNotEmpty,
      TranslationEngineId.deepL => prefs.apiKey.trim().isNotEmpty,
      TranslationEngineId.offlineTranslator => offlineTranslatorSupported,
    };
  }

  String targetCode(TranslationPrefs prefs, String uiLanguageCode) {
    return prefs.engine == TranslationEngineId.deepL
        ? DeepLEngine.normalizeTarget(uiLanguageCode)
        : uiLanguageCode.split(RegExp(r'[-_]')).first.toLowerCase();
  }

  /// Translate [text] into [targetLang] and close the client for this call.
  ///
  /// [targetLang] is an ISO 639 tag (`zh`, `en`). DeepL's uppercase form is
  /// applied inside the engine.
  Future<TranslationResult> translateTo(
    String text, {
    required TranslationPrefs prefs,
    required String targetLang,
  }) async {
    if (!isConfigured(prefs)) {
      throw StateError('translation_not_configured');
    }
    final target = targetLang.trim();
    if (target.isEmpty) {
      throw StateError('translation_target_empty');
    }
    http.Client? client;
    try {
      final engine = switch (prefs.engine) {
        TranslationEngineId.offlineTranslator => OfflineTranslatorEngine(),
        TranslationEngineId.libreTranslate => LibreTranslateEngine(
          baseUrl: prefs.baseUrl,
          apiKey: prefs.apiKey,
          client: client = _clientFactory(),
        ),
        TranslationEngineId.deepL => DeepLEngine(
          apiKey: prefs.apiKey,
          pro: prefs.deepLPro,
          client: client = _clientFactory(),
        ),
      };
      return await engine.translate(text: text, targetLang: target);
    } finally {
      client?.close();
    }
  }

  /// Translate and close the HTTP client created for this call.
  ///
  /// The target is the UI language.
  Future<TranslationResult> translateOnce(
    String text, {
    required TranslationPrefs prefs,
    required String uiLanguageCode,
  }) {
    return translateTo(
      text,
      prefs: prefs,
      targetLang: targetCode(prefs, uiLanguageCode),
    );
  }

  Future<void> testConnection({
    required TranslationPrefs prefs,
    required String uiLanguageCode,
  }) async {
    await translateOnce('Hello', prefs: prefs, uiLanguageCode: uiLanguageCode);
  }
}

final translationService = TranslationService();
