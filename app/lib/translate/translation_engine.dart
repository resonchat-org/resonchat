// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Which translation backend to use (no in-app MT).
enum TranslationEngineId { libreTranslate, deepL, offlineTranslator }

extension TranslationEngineIdX on TranslationEngineId {
  String get stored => switch (this) {
    TranslationEngineId.libreTranslate => 'libretranslate',
    TranslationEngineId.deepL => 'deepl',
    TranslationEngineId.offlineTranslator => 'offline_translator',
  };

  static TranslationEngineId? tryParse(String? raw) {
    switch (raw) {
      case 'libretranslate':
        return TranslationEngineId.libreTranslate;
      case 'deepl':
        return TranslationEngineId.deepL;
      case 'offline_translator':
        return TranslationEngineId.offlineTranslator;
      default:
        return null;
    }
  }
}

class TranslationResult {
  const TranslationResult({required this.text, this.detectedSource});

  final String text;
  final String? detectedSource;
}

/// One external translation backend.
abstract class TranslationEngine {
  TranslationEngineId get id;

  /// Translates [text] into [targetLang] (engine-specific code, e.g. `zh` / `ZH`).
  Future<TranslationResult> translate({
    required String text,
    required String targetLang,
    String sourceLang = 'auto',
  });

  /// Lightweight reachability check (translate a fixed string).
  Future<void> testConnection({required String targetLang});
}
