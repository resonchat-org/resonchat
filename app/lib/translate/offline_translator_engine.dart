// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Offline Translator (dev.davidv.translator) on Android. The other app
// exposes ITranslationService over a binder; this is the Dart side of
// that call. Other platforms have no such service.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:resonchat/translate/translation_engine.dart';

const offlineTranslatorChannel = MethodChannel(
  'org.resonchat.resonchat/offline_translator',
);

/// True only on Android, where Offline Translator can be installed.
bool get offlineTranslatorSupported =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

class OfflineTranslatorEngine implements TranslationEngine {
  OfflineTranslatorEngine({MethodChannel? channel})
    : _channel = channel ?? offlineTranslatorChannel;

  final MethodChannel _channel;

  @override
  TranslationEngineId get id => TranslationEngineId.offlineTranslator;

  @override
  Future<TranslationResult> translate({
    required String text,
    required String targetLang,
    String sourceLang = 'auto',
  }) async {
    if (!offlineTranslatorSupported) {
      throw StateError('Offline Translator is only available on Android');
    }
    final from = sourceLang == 'auto' ? '' : sourceLang;
    try {
      final translated = await _channel.invokeMethod<String>('translate', {
        'text': text,
        'from': from,
        'to': targetLang,
      });
      if (translated == null || translated.trim().isEmpty) {
        throw StateError('Offline Translator: empty translation');
      }
      return TranslationResult(text: translated);
    } on PlatformException catch (e) {
      throw StateError(e.message ?? 'Offline Translator failed');
    }
  }

  @override
  Future<void> testConnection({required String targetLang}) async {
    await translate(text: 'Hello', targetLang: targetLang);
  }
}
