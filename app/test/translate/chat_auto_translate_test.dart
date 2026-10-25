// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';
import 'package:moxxmpp/moxxmpp.dart';

import 'package:resonchat/translate/chat_auto_translate.dart';

void main() {
  test('auto-translate is one language or off', () {
    const off = ChatAutoTranslate.off;
    const replace = ChatAutoTranslate(lang: 'ja');
    expect(off.isOff, isTrue);
    expect(replace.isOff, isFalse);
    expect(replace.lang, 'ja');
  });

  test('UI language prefers an exact tag and skips a local original', () {
    const rows = [
      (lang: 'zh-Hans', text: '松'),
      (lang: 'zh', text: '紧'),
      (lang: 'en', text: 'tight'),
      (lang: kLocalOriginalLang, text: 'typed'),
    ];
    expect(translationMatchingUi(rows, 'zh'), '紧');
    expect(translationMatchingUi(rows, 'en'), 'tight');
    expect(translationMatchingUi(rows, 'ja'), isNull);
    expect(
      translationMatchingUi(const [(lang: 'zh-Hans', text: '松')], 'zh'),
      '松',
    );
    expect(
      translationMatchingUi(const [
        (lang: kLocalOriginalLang, text: 'typed'),
      ], 'en'),
      isNull,
    );
  });

  test('the first pair for the UI language is chosen', () {
    const pairs = [
      TranslationLanguagePair(sourceLang: 'en', destinationLang: 'fr'),
      TranslationLanguagePair(
        sourceLang: 'en',
        destinationLang: 'zh',
        dictionary: 'medical',
      ),
    ];
    final chosen = translationPairForUi(pairs, 'zh-Hans');
    expect(chosen?.destinationLang, 'zh');
    expect(chosen?.dictionary, 'medical');
    expect(translationPairForUi(pairs, 'ja'), isNull);
  });

  test('a remote translation names its engine on the next line', () {
    expect(remoteTranslationLine('你好', 'default'), '你好\ndefault');
    expect(remoteTranslationLine('你好', '  '), '你好');
  });
}
