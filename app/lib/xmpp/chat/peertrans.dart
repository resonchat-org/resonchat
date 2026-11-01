// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Peer Message Translation (`urn:resonchat:peertrans:0`).
//
// Wire shape = XEP-0171 Direct Translation (destination bodies + langtrans)
// + XEP-0461 reply + <peertrans/>. Source body is omitted (lives on parent).
// Receive-only: bots/peers publish; this client parses, ranks, and merges.
// See docs/12-peertrans.md.

import 'package:moxxmpp/moxxmpp.dart';

import 'package:resonchat/xmpp/inbound/reply_info.dart';

/// Wire namespace for `<peertrans/>`.
const String peertransXmlns = 'urn:resonchat:peertrans:0';

/// Account pref: when `1`, only MUC owner/admin peertrans is merged.
const String prefPeertransAdminsOnlyKey = 'pref_peertrans_admins_only';

/// Clamps a wire `priority` attribute to the effective 0..9 scale.
int peertransEffectivePriority(String? raw) {
  final n = int.tryParse((raw ?? '').toString().trim());
  if (n == null || n < 0 || n > 9) return 0;
  return n;
}

/// Primary language subtag for matching (`zh-Hans` → `zh`).
String peertransLangPrimary(String tag) {
  final trimmed = tag.trim().toLowerCase().replaceAll('_', '-');
  if (trimmed.isEmpty) return '';
  return trimmed.split('-').first;
}

/// One destination language carried on a peertrans stanza.
class PeerTransLangBody {
  const PeerTransLangBody({
    required this.lang,
    required this.text,
    this.sourceLang,
    this.engine,
  });

  final String lang;
  final String text;
  final String? sourceLang;
  final String? engine;
}

/// Parsed peertrans = 0171 Direct payload + reply + marker.
class PeerTransData implements StanzaHandlerExtension {
  const PeerTransData({
    required this.priority,
    required this.bodies,
    required this.parentId,
    this.parentTo,
    this.langTrans,
  });

  /// Effective priority 0..9.
  final int priority;

  /// Destination bodies from XEP-0171 Direct, reply-fallback already stripped.
  ///
  /// May be empty when the marker+reply are valid but the destination text
  /// could not be recovered — the stanza must still be consumed (no bubble).
  final List<PeerTransLangBody> bodies;

  /// XEP-0461 reply id (parent origin-id or MUC stanza-id).
  final String parentId;

  /// Optional `reply/@to`.
  final String? parentTo;

  /// Underlying XEP-0171 Direct parse (destination bodies + hints).
  final LangTransData? langTrans;

  /// Reads peertrans from a decrypted (or plaintext) message [stanza].
  ///
  /// Requires `<peertrans/>` and `<reply id='…'/>`. When those are present the
  /// result is non-null so the client swallows the stanza (no independent
  /// bubble), even if destination bodies cannot be recovered.
  static PeerTransData? fromStanza(XMLNode stanza) {
    final marker = stanza.firstTag('peertrans', xmlns: peertransXmlns);
    if (marker == null) return null;

    final reply = stanza.firstTag('reply', xmlns: replyXmlns);
    final parentId = (reply?.attributes['id'] ?? '').toString().trim();
    if (parentId.isEmpty) return null;

    final langTrans = LangTransData.fromStanza(stanza);
    final replyMeta = _replyFallbackMeta(stanza, parentId);
    final bodies = _destinationBodies(
      stanza: stanza,
      langTrans: langTrans,
      replyMeta: replyMeta,
    );

    final parentTo = reply?.attributes['to']?.toString().trim();
    return PeerTransData(
      priority: peertransEffectivePriority(
        marker.attributes['priority']?.toString(),
      ),
      bodies: bodies,
      parentId: parentId,
      parentTo: (parentTo == null || parentTo.isEmpty) ? null : parentTo,
      langTrans: langTrans,
    );
  }
}

/// Destination texts for peertrans, with a lenient fallback when strict
/// XEP-0171 body/`xml:lang` matching fails (e.g. server stripped xml:lang).
List<PeerTransLangBody> _destinationBodies({
  required XMLNode stanza,
  required LangTransData? langTrans,
  required ReplyData? replyMeta,
}) {
  final bodies = <PeerTransLangBody>[];
  final seen = <String>{};

  void add({
    required String lang,
    required String rawText,
    String? sourceLang,
    String? engine,
  }) {
    final primary = peertransLangPrimary(lang);
    if (primary.isEmpty || !seen.add(primary)) return;
    var text = rawText;
    if (replyMeta != null) {
      text = stripFallback(replyMeta, text).trim();
    } else {
      text = text.trim();
    }
    if (text.isEmpty) return;
    bodies.add(
      PeerTransLangBody(
        lang: primary,
        text: text,
        sourceLang: (sourceLang == null || sourceLang.isEmpty)
            ? null
            : peertransLangPrimary(sourceLang),
        engine: engine,
      ),
    );
  }

  if (langTrans != null) {
    for (final t in langTrans.translations) {
      add(
        lang: t.destinationLang,
        rawText: t.text,
        sourceLang: t.sourceLang ?? langTrans.sourceLang,
        engine: t.engine,
      );
    }
    if (bodies.isNotEmpty) return bodies;
  }

  // Strict 0171 failed (missing/mismatched xml:lang). Recover from the
  // langtrans hint + whatever <body/> elements are on the stanza.
  final x = stanza.firstTag('x', xmlns: langtransXmlns);
  if (x == null) return bodies;
  final wireBodies = stanza.findTags('body');
  if (wireBodies.isEmpty) return bodies;

  for (final child in x.children) {
    if (child.tag != 'translation') continue;
    final dest = (child.attributes['destination_lang'] ?? '').toString().trim();
    if (dest.isEmpty) continue;
    final matched =
        _bodyTextForLang(wireBodies, dest) ??
        (wireBodies.length == 1 ? wireBodies.first.innerText() : null);
    if (matched == null) continue;
    add(
      lang: dest,
      rawText: matched,
      sourceLang: (child.attributes['source_lang'] ?? '').toString(),
      engine: (child.attributes['engine'] ?? '').toString(),
    );
  }
  return bodies;
}

String? _bodyTextForLang(List<XMLNode> bodies, String lang) {
  for (final body in bodies) {
    final tag = (body.attributes['xml:lang'] ?? '').toString().trim();
    if (tag.isNotEmpty && xmppLanguageTagsMatch(tag, lang)) {
      return body.innerText();
    }
  }
  return null;
}

ReplyData? _replyFallbackMeta(XMLNode stanza, String parentId) {
  final fallback = stanza.firstTag('fallback', xmlns: fallbackIndicationXmlns);
  if (fallback == null) return null;
  final forAttr = (fallback.attributes['for'] ?? '').toString();
  if (forAttr.isNotEmpty && forAttr != replyXmlns) return null;
  final body = fallback.firstTag('body');
  if (body == null) return null;
  final start = int.tryParse((body.attributes['start'] ?? '').toString());
  final end = int.tryParse((body.attributes['end'] ?? '').toString());
  if (start == null || end == null) return null;
  return ReplyData(parentId, start: start, end: end);
}

/// Ranking view of one candidate (avoids clashing with Drift row type).
class PeerTransRanked {
  const PeerTransRanked({
    required this.priority,
    required this.sender,
    required this.supplementId,
    required this.timestamp,
    required this.body,
  });

  final int priority;
  final String sender;
  final String supplementId;
  final DateTime timestamp;
  final String body;
}

/// Picks the display winner: higher priority, then earlier timestamp, then id.
PeerTransRanked? selectPeerTransWinner(Iterable<PeerTransRanked> all) {
  PeerTransRanked? best;
  for (final c in all) {
    if (best == null) {
      best = c;
      continue;
    }
    if (c.priority > best.priority) {
      best = c;
      continue;
    }
    if (c.priority < best.priority) continue;
    final byTime = c.timestamp.compareTo(best.timestamp);
    if (byTime < 0) {
      best = c;
      continue;
    }
    if (byTime > 0) continue;
    if (c.supplementId.compareTo(best.supplementId) < 0) best = c;
  }
  return best;
}

/// Whether [affiliation] is MUC owner or admin (client trust filter).
bool peertransSenderIsAdmin(String? affiliation) {
  final a = (affiliation ?? '').trim().toLowerCase();
  return a == 'owner' || a == 'admin';
}

/// Short label for a peertrans sender: MUC nick as-is, bare JID → localpart.
String peertransSourceLabel(String sender) {
  final s = sender.trim();
  if (s.isEmpty) return '';
  final at = s.indexOf('@');
  if (at > 0) return s.substring(0, at);
  return s;
}
