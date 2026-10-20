// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:resonchat/persistence/prefs_database.dart';
import 'package:resonchat/translate/translation_engine.dart';

const prefTranslationEngineKey = 'pref_translation_engine';
const prefTranslationBaseUrlKey = 'pref_translation_base_url';
const prefTranslationApiKeyKey = 'pref_translation_api_key';
const prefTranslationDeepLProKey = 'pref_translation_deepl_pro';

class TranslationPrefs {
  const TranslationPrefs({
    required this.engine,
    required this.baseUrl,
    required this.apiKey,
    required this.deepLPro,
  });

  final TranslationEngineId engine;
  final String baseUrl;
  final String apiKey;

  /// When true, DeepL uses `api.deepl.com` instead of `api-free.deepl.com`.
  final bool deepLPro;

  static const defaults = TranslationPrefs(
    engine: TranslationEngineId.libreTranslate,
    baseUrl: '',
    apiKey: '',
    deepLPro: false,
  );

  Future<void> save([PrefsDatabase? prefs]) async {
    final db = prefs ?? appPrefs;
    await db.setString(prefTranslationEngineKey, engine.stored);
    await db.setString(prefTranslationBaseUrlKey, baseUrl.trim());
    await db.setString(prefTranslationApiKeyKey, apiKey.trim());
    await db.setString(prefTranslationDeepLProKey, deepLPro ? '1' : '0');
  }

  static Future<TranslationPrefs> load([PrefsDatabase? prefs]) async {
    final db = prefs ?? appPrefs;
    final engine =
        TranslationEngineIdX.tryParse(
          await db.getString(prefTranslationEngineKey),
        ) ??
        TranslationEngineId.libreTranslate;
    final baseUrl = (await db.getString(prefTranslationBaseUrlKey)) ?? '';
    final apiKey = (await db.getString(prefTranslationApiKeyKey)) ?? '';
    final deepLPro = (await db.getString(prefTranslationDeepLProKey)) == '1';
    return TranslationPrefs(
      engine: engine,
      baseUrl: baseUrl,
      apiKey: apiKey,
      deepLPro: deepLPro,
    );
  }
}
