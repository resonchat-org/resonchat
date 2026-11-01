// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Per-conversation auto-translate. Outgoing text is replaced with one
// translation. The typed original stays in the local database.

import 'package:moxxmpp/moxxmpp.dart'
    show xmppLanguagePrimary, xmppLanguageTagsMatch;

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

/// One stored translation considered for UI display.
typedef TranslationDisplayRow = ({
  String lang,
  String text,
  String engine,
  String by,
});

/// The translation whose language matches [uiLanguageCode], if any.
///
/// An exact tag wins over a primary-subtag match (`zh` over `zh-Hans` when
/// the UI is `zh` only if both exist — exact `zh` is preferred). Rows that
/// hold a locally kept original are skipped.
TranslationDisplayRow? translationMatchingUi(
  Iterable<TranslationDisplayRow> rows,
  String uiLanguageCode,
) {
  final ui = uiLanguageCode.trim().toLowerCase();
  if (ui.isEmpty) return null;
  TranslationDisplayRow? loose;
  for (final row in rows) {
    if (row.lang == kLocalOriginalLang) continue;
    if (row.text.trim().isEmpty) continue;
    if (row.lang.trim().toLowerCase() == ui) return row;
    if (loose == null && xmppLanguageTagsMatch(row.lang, ui)) {
      loose = row;
    }
  }
  return loose;
}

/// Translation strip under a bubble: body plus optional engine / source marks.
///
/// Direct (sender's own) leaves [source] empty. Peertrans sets a nick; local
/// translate sets a localized "Local" label. [engine] is shown whenever set.
class BubbleTranslation {
  const BubbleTranslation({
    required this.text,
    this.engine = '',
    this.source = '',
  });

  /// Translated (or local-original) body.
  final String text;

  /// Engine name (XEP-0171 or local backend).
  final String engine;

  /// Attribution: empty (Direct), peer nick, or localized "Local".
  final String source;

  /// Leading mark shown before the body (`DeepL(alice)` / `DeepL`).
  String get marker {
    final eng = engine.trim();
    final src = source.trim();
    if (eng.isEmpty) return src;
    if (src.isEmpty) return eng;
    return '$eng($src)';
  }

  bool get isEmpty => text.trim().isEmpty && marker.isEmpty;
}
