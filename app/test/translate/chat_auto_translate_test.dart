// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';

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
    const rows = <TranslationDisplayRow>[
      (lang: 'zh-Hans', text: '松', engine: 'A', by: ''),
      (lang: 'zh', text: '紧', engine: 'B', by: 'bot'),
      (lang: 'en', text: 'tight', engine: 'C', by: ''),
      (lang: kLocalOriginalLang, text: 'typed', engine: '', by: ''),
    ];
    expect(translationMatchingUi(rows, 'zh')?.text, '紧');
    expect(translationMatchingUi(rows, 'zh')?.by, 'bot');
    expect(translationMatchingUi(rows, 'en')?.text, 'tight');
    expect(translationMatchingUi(rows, 'ja'), isNull);
    expect(
      translationMatchingUi(const [
        (lang: 'zh-Hans', text: '松', engine: 'A', by: ''),
      ], 'zh')?.text,
      '松',
    );
    expect(
      translationMatchingUi(const [
        (lang: kLocalOriginalLang, text: 'typed', engine: '', by: ''),
      ], 'en'),
      isNull,
    );
  });

  test('caption marker leads: engine(source)', () {
    expect(
      const BubbleTranslation(text: '你好', engine: 'DeepL').marker,
      'DeepL',
    );
    expect(
      const BubbleTranslation(
        text: '你好',
        engine: 'DeepL',
        source: 'alice',
      ).marker,
      'DeepL(alice)',
    );
    expect(
      const BubbleTranslation(
        text: '你好',
        engine: 'LibreTranslate',
        source: 'Local',
      ).marker,
      'LibreTranslate(Local)',
    );
    expect(const BubbleTranslation(text: '你好').marker, '');
    expect(const BubbleTranslation(text: '', engine: 'DeepL').isEmpty, isFalse);
    expect(const BubbleTranslation(text: '  ').isEmpty, isTrue);
  });
}
