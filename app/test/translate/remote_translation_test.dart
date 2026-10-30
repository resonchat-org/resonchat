// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:moxlib/moxlib.dart';
import 'package:moxxmpp/moxxmpp.dart';
import 'package:test/test.dart';

import 'package:resonchat/translate/remote_translation.dart';
import 'package:resonchat/ui/accounts/translation_provider_sheet.dart';

void main() {
  test('source_lang und and empty are omitted on the translation IQ', () {
    expect(sourceLangForTranslationRequest('und'), isNull);
    expect(sourceLangForTranslationRequest('UND'), isNull);
    expect(sourceLangForTranslationRequest(''), isNull);
    expect(sourceLangForTranslationRequest(null), isNull);
    expect(sourceLangForTranslationRequest('en'), 'en');
    expect(sourceLangForTranslationRequest('zh-CN'), 'zh');
  });

  test('disco info must advertise automation/translation and langtrans', () {
    final jid = JID.fromString('translation.example.com');
    final ok = DiscoInfo(
      const [langtransXmlns],
      const [Identity(category: 'automation', type: 'translation')],
      const [],
      null,
      jid,
    );
    final missingFeature = DiscoInfo(
      const [],
      const [Identity(category: 'automation', type: 'translation')],
      const [],
      null,
      jid,
    );
    final wrongIdentity = DiscoInfo(
      const [langtransXmlns],
      const [Identity(category: 'automation', type: 'command-list')],
      const [],
      null,
      jid,
    );
    expect(isTranslationProviderDisco(ok), isTrue);
    expect(isTranslationProviderDisco(missingFeature), isFalse);
    expect(isTranslationProviderDisco(wrongIdentity), isFalse);
  });

  test('provider JID may be bare, full, or a component (XEP §4.2.2)', () {
    expect(
      looksLikeTranslationProviderJid('bot@example.com/translator'),
      isTrue,
    );
    expect(looksLikeTranslationProviderJid('translation.example.com'), isTrue);
    expect(looksLikeTranslationProviderJid('bot@example.com'), isTrue);
    expect(
      looksLikeTranslationProviderJid('towerofbabel@shakespeare.lit'),
      isTrue,
    );
    expect(looksLikeTranslationProviderJid('not a jid'), isFalse);
    expect(looksLikeTranslationProviderJid('bot@example.com/'), isFalse);
    expect(looksLikeTranslationProviderJid(''), isFalse);
    expect(looksLikeTranslationProviderJid('bot@'), isFalse);
  });

  test('configured provider JID skips server discovery', () async {
    final provider = JID.fromString('test@example.com/translator');
    var discoverCalls = 0;
    final queried = <String>[];
    final providers = await resolveTranslationProviders(
      queryItems: (jid) async {
        queried.add(jid.toString());
        return Result<StanzaError, List<TranslationLanguagePair>>([
          const TranslationLanguagePair(
            sourceLang: 'und',
            destinationLang: 'zh',
          ),
        ]);
      },
      discoverCandidates: () async {
        discoverCalls++;
        return [
          TranslationProviderCandidate(
            jid: JID.fromString('ignored@example.com'),
          ),
        ];
      },
      providerJid: provider,
    );
    expect(discoverCalls, 0);
    expect(queried, ['test@example.com/translator']);
    expect(providers, isNotNull);
    expect(providers!.single.jid, provider);
    expect(providers.single.pairs.single.destinationLang, 'zh');
  });

  test('without a configured JID, each disco candidate is queried', () async {
    final a = JID.fromString('a@example.com/translator');
    final b = JID.fromString('translation.example.com');
    final queried = <String>[];
    final providers = await resolveTranslationProviders(
      queryItems: (jid) async {
        queried.add(jid.toString());
        return Result<StanzaError, List<TranslationLanguagePair>>([
          TranslationLanguagePair(
            sourceLang: 'en',
            destinationLang: 'fr',
            jid: jid.toString(),
          ),
        ]);
      },
      discoverCandidates: () async => [
        TranslationProviderCandidate(jid: a, name: 'Bot'),
        TranslationProviderCandidate(jid: b),
      ],
    );
    expect(queried, [a.toString(), b.toString()]);
    expect(providers!.map((p) => p.jid.toString()).toList(), [
      a.toString(),
      b.toString(),
    ]);
  });
}
