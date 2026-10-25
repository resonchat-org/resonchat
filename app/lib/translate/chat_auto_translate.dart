// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Per-conversation auto-translate. Outgoing text is replaced with one
// translation. The typed original stays in the local database.

import 'package:moxxmpp/moxxmpp.dart'
    show TranslationLanguagePair, xmppLanguagePrimary, xmppLanguageTagsMatch;

/// A language the auto-translate picker offers. The label is the language's
/// own name, so it stays readable when the UI language is the other one.
class TranslateLanguage {
  const TranslateLanguage(this.code, this.label);

  final String code;
  final String label;
}

const kTranslateLanguages = <TranslateLanguage>[
  TranslateLanguage('en', 'English'),
  TranslateLanguage('zh', '中文'),
  TranslateLanguage('ja', '日本語'),
  TranslateLanguage('ko', '한국어'),
  TranslateLanguage('es', 'Español'),
  TranslateLanguage('fr', 'Français'),
  TranslateLanguage('de', 'Deutsch'),
  TranslateLanguage('pt', 'Português'),
  TranslateLanguage('ru', 'Русский'),
  TranslateLanguage('ar', 'العربية'),
  TranslateLanguage('it', 'Italiano'),
];

/// `message_translations.lang` for the typed text kept under a replaced send.
///
/// Not a language tag, so it is not shown as somebody else's translation.
const kLocalOriginalLang = 'original';

/// A detected source language worth storing, or null.
String? languageTag(String? raw) {
  if (raw == null) return null;
  final primary = xmppLanguagePrimary(raw);
  if (primary.length < 2 || primary == 'auto' || primary == 'und') return null;
  return primary;
}

String translateLanguageLabel(String code) {
  for (final lang in kTranslateLanguages) {
    if (lang.code == code) return lang.label;
  }
  return code;
}

/// What one conversation does with outgoing text. Null [lang] is off.
class ChatAutoTranslate {
  const ChatAutoTranslate({this.lang});

  static const off = ChatAutoTranslate();

  /// Target language, a primary tag, or null when off.
  final String? lang;

  bool get isOff => lang == null || lang!.isEmpty;
}

/// The translation whose language matches [uiLanguageCode], if any.
///
/// An exact tag wins over a primary-subtag match (`zh` over `zh-Hans` when
/// the UI is `zh` only if both exist — exact `zh` is preferred). Rows that
/// hold a locally kept original are skipped.
String? translationMatchingUi(
  Iterable<({String lang, String text})> rows,
  String uiLanguageCode,
) {
  final ui = uiLanguageCode.trim().toLowerCase();
  if (ui.isEmpty) return null;
  String? loose;
  for (final row in rows) {
    if (row.lang == kLocalOriginalLang) continue;
    if (row.text.trim().isEmpty) continue;
    if (row.lang.trim().toLowerCase() == ui) return row.text;
    if (loose == null && xmppLanguageTagsMatch(row.lang, ui)) {
      loose = row.text;
    }
  }
  return loose;
}

/// First advertised pair whose destination matches [uiLanguageCode].
TranslationLanguagePair? translationPairForUi(
  Iterable<TranslationLanguagePair> pairs,
  String uiLanguageCode,
) {
  for (final pair in pairs) {
    if (xmppLanguageTagsMatch(pair.destinationLang, uiLanguageCode)) {
      return pair;
    }
  }
  return null;
}

/// Translation text with the engine name on the following line, when known.
String remoteTranslationLine(String text, String? engine) {
  final name = engine?.trim() ?? '';
  if (name.isEmpty) return text;
  return '$text\n$name';
}
