// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

/// Which external HTTP engine to use (no in-app MT).
enum TranslationEngineId { libreTranslate, deepL }

extension TranslationEngineIdX on TranslationEngineId {
  String get stored => switch (this) {
    TranslationEngineId.libreTranslate => 'libretranslate',
    TranslationEngineId.deepL => 'deepl',
  };

  static TranslationEngineId? tryParse(String? raw) {
    switch (raw) {
      case 'libretranslate':
        return TranslationEngineId.libreTranslate;
      case 'deepl':
        return TranslationEngineId.deepL;
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
