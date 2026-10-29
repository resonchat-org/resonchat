// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Discover a remote XEP-0171 translation provider and ask it to translate.
// This client does not translate on the provider's behalf.

import 'package:moxlib/moxlib.dart';
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

/// One disco hit that advertises XEP-0171 (before langtrans:items).
class TranslationProviderCandidate {
  const TranslationProviderCandidate({required this.jid, this.name});

  final JID jid;
  final String? name;
}

/// One provider JID plus the language pairs it advertised.
class DiscoveredTranslator {
  const DiscoveredTranslator({required this.jid, required this.pairs});

  final JID jid;
  final List<TranslationLanguagePair> pairs;
}

/// Whether [info] identifies an XEP-0171 translation provider (§4.2.2).
bool isTranslationProviderDisco(DiscoInfo info) {
  return info.features.contains(langtransXmlns) &&
      info.identities.any(
        (identity) =>
            identity.category == 'automation' && identity.type == 'translation',
      );
}

/// Source language for a translation IQ: omit `und` / empty (auto-detect).
String? sourceLangForTranslationRequest(String? advertised) {
  final primary = xmppLanguagePrimary(advertised ?? '');
  if (primary.isEmpty || primary == 'und') return null;
  return primary;
}

/// Loads language pairs for a configured provider, or for each disco candidate.
///
/// When [providerJid] is set, [discoverCandidates] is not called.
Future<List<DiscoveredTranslator>?> resolveTranslationProviders({
  required Future<Result<StanzaError, List<TranslationLanguagePair>>> Function(
    JID jid,
  )
  queryItems,
  required Future<List<TranslationProviderCandidate>?> Function()
  discoverCandidates,
  JID? providerJid,
}) async {
  if (providerJid != null) {
    final pairs = await queryItems(providerJid);
    if (!pairs.isType<List<TranslationLanguagePair>>()) return null;
    return [
      DiscoveredTranslator(
        jid: providerJid,
        pairs: pairs.get<List<TranslationLanguagePair>>(),
      ),
    ];
  }
  final candidates = await discoverCandidates();
  if (candidates == null) return null;
  final found = <DiscoveredTranslator>[];
  for (final candidate in candidates) {
    final pairs = await queryItems(candidate.jid);
    if (!pairs.isType<List<TranslationLanguagePair>>()) continue;
    found.add(
      DiscoveredTranslator(
        jid: candidate.jid,
        pairs: pairs.get<List<TranslationLanguagePair>>(),
      ),
    );
  }
  return found;
}

/// Finds translation providers on the account's server and requests a
/// translation. The discovered list is kept until [clear].
class RemoteTranslationClient {
  List<DiscoveredTranslator>? _cached;
  String? _cachedProviderKey;

  void clear() {
    _cached = null;
    _cachedProviderKey = null;
  }

  /// §4.2.1 + §4.2.2: list translation providers attached to [server].
  ///
  /// Does not query `urn:xmpp:langtrans:items`; used by the account UI so the
  /// user can pick a JID to store.
  Future<List<TranslationProviderCandidate>?> discoverProviderCandidates({
    required DiscoManager disco,
    required JID server,
  }) async {
    final items = await disco.discoItemsQuery(server);
    if (!items.isType<List<DiscoItem>>()) return null;
    final found = <TranslationProviderCandidate>[];
    for (final item in items.get<List<DiscoItem>>()) {
      final info = await disco.discoInfoQuery(item.jid);
      if (!info.isType<DiscoInfo>()) continue;
      if (!isTranslationProviderDisco(info.get<DiscoInfo>())) continue;
      final name = item.name?.trim();
      found.add(
        TranslationProviderCandidate(
          jid: item.jid,
          name: name == null || name.isEmpty ? null : name,
        ),
      );
    }
    return found;
  }

  Future<RemoteTranslationOutcome> translate({
    required DiscoManager disco,
    required LanguageTranslationManager lang,
    required JID server,
    required String text,
    required String uiLanguage,
    JID? providerJid,
  }) async {
    final providers = await _providers(
      disco,
      lang,
      server,
      providerJid: providerJid,
    );
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
    final target = chosen.jid == null || chosen.jid!.isEmpty
        ? chosenProvider.jid
        : JID.fromString(chosen.jid!);
    final result = await lang.requestTranslation(
      target,
      text: text,
      sourceLang: sourceLangForTranslationRequest(chosen.sourceLang),
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
    JID server, {
    JID? providerJid,
  }) async {
    final key = providerJid?.toString() ?? server.toString();
    final cached = _cached;
    if (cached != null && _cachedProviderKey == key) return cached;

    final found = await resolveTranslationProviders(
      queryItems: lang.queryItems,
      discoverCandidates: () =>
          discoverProviderCandidates(disco: disco, server: server),
      providerJid: providerJid,
    );
    if (found == null) return null;
    _cachedProviderKey = key;
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
