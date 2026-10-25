// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Discover a remote XEP-0171 translation provider and ask it to translate.
// This client does not translate on the provider's behalf.

import 'package:moxxmpp/moxxmpp.dart';

import 'package:resonchat/translate/chat_auto_translate.dart';

/// Why a remote translation request produced no text.
enum RemoteTranslationReject { notConnected, noService, noLanguage, failed }

/// Text from a translation provider, or why none came back.
class RemoteTranslationOutcome {
  const RemoteTranslationOutcome.ready(this.text, {this.engine})
    : reject = null,
      detail = null;

  const RemoteTranslationOutcome.reject(this.reject, {this.detail})
    : text = null,
      engine = null;

  final String? text;
  final String? engine;
  final RemoteTranslationReject? reject;
  final String? detail;

  bool get isReady => text != null && text!.isNotEmpty;
}

/// One provider JID plus the language pairs it advertised.
class DiscoveredTranslator {
  const DiscoveredTranslator({required this.jid, required this.pairs});

  final JID jid;
  final List<TranslationLanguagePair> pairs;
}

/// Finds translation providers on the account's server and requests a
/// translation. The discovered list is kept until [clear].
class RemoteTranslationClient {
  List<DiscoveredTranslator>? _cached;

  void clear() => _cached = null;

  Future<RemoteTranslationOutcome> translate({
    required DiscoManager disco,
    required LanguageTranslationManager lang,
    required JID server,
    required String text,
    required String uiLanguage,
  }) async {
    final providers = await _providers(disco, lang, server);
    if (providers == null) {
      return const RemoteTranslationOutcome.reject(
        RemoteTranslationReject.noService,
      );
    }
    DiscoveredTranslator? chosenProvider;
    TranslationLanguagePair? chosen;
    for (final provider in providers) {
      final pair = translationPairForUi(provider.pairs, uiLanguage);
      if (pair == null) continue;
      chosenProvider = provider;
      chosen = pair;
      break;
    }
    if (chosenProvider == null || chosen == null) {
      return RemoteTranslationOutcome.reject(
        providers.isEmpty
            ? RemoteTranslationReject.noService
            : RemoteTranslationReject.noLanguage,
      );
    }
    final result = await lang.requestTranslation(
      chosen.jid == null || chosen.jid!.isEmpty
          ? chosenProvider.jid
          : JID.fromString(chosen.jid!),
      text: text,
      sourceLang: chosen.sourceLang,
      destinationLang: chosen.destinationLang,
      dictionary: chosen.dictionary,
    );
    if (!result.isType<TranslationResponse>()) {
      return RemoteTranslationOutcome.reject(
        RemoteTranslationReject.failed,
        detail: _errorDetail(result.get<StanzaError>()),
      );
    }
    final response = result.get<TranslationResponse>();
    final item = response.translations.isEmpty
        ? null
        : response.translations.first;
    if (item == null || item.text.trim().isEmpty) {
      return const RemoteTranslationOutcome.reject(
        RemoteTranslationReject.failed,
      );
    }
    return RemoteTranslationOutcome.ready(item.text, engine: item.engine);
  }

  Future<List<DiscoveredTranslator>?> _providers(
    DiscoManager disco,
    LanguageTranslationManager lang,
    JID server,
  ) async {
    final cached = _cached;
    if (cached != null) return cached;
    final items = await disco.discoItemsQuery(server);
    if (!items.isType<List<DiscoItem>>()) return null;
    final found = <DiscoveredTranslator>[];
    for (final item in items.get<List<DiscoItem>>()) {
      final info = await disco.discoInfoQuery(item.jid);
      if (!info.isType<DiscoInfo>()) continue;
      final discoInfo = info.get<DiscoInfo>();
      final translates =
          discoInfo.features.contains(langtransXmlns) &&
          discoInfo.identities.any(
            (identity) =>
                identity.category == 'automation' &&
                identity.type == 'translation',
          );
      if (!translates) continue;
      final pairs = await lang.queryItems(item.jid);
      if (!pairs.isType<List<TranslationLanguagePair>>()) continue;
      found.add(
        DiscoveredTranslator(
          jid: item.jid,
          pairs: pairs.get<List<TranslationLanguagePair>>(),
        ),
      );
    }
    _cached = found;
    return found;
  }
}

String _errorDetail(StanzaError error) {
  if (error is GenericStanzaError) {
    if (error.text.isNotEmpty) return error.text;
    if (error.condition.isNotEmpty) return error.condition;
  }
  return '$error';
}
