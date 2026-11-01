// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Incoming `<peertrans/>` → [PeerTransData] on the message event.

import 'package:moxxmpp/moxxmpp.dart';

import 'package:resonchat/xmpp/chat/peertrans.dart';

const String peertransManagerId = 'resonchat.peertrans';

/// Parses peertrans markers on inbound messages (receive-only).
class PeerTransManager extends XmppManagerBase {
  PeerTransManager() : super(peertransManagerId);

  @override
  Future<bool> isSupported() async => true;

  @override
  List<String> getDiscoFeatures() => [peertransXmlns];

  @override
  List<StanzaHandler> getIncomingStanzaHandlers() => [
    StanzaHandler(
      stanzaTag: 'message',
      tagName: 'peertrans',
      tagXmlns: peertransXmlns,
      callback: _onMessage,
      // With other message extensions; must run before MessageManager (-100).
      priority: messageExtensionPriority,
    ),
  ];

  Future<StanzaHandlerData> _onMessage(
    Stanza stanza,
    StanzaHandlerData state,
  ) async {
    // Never let a parse glitch fall through as a normal chat bubble: the
    // handler only matches when <peertrans/> is present, and fromStanza
    // returns non-null whenever reply@id is usable.
    try {
      final parsed = PeerTransData.fromStanza(state.stanza);
      if (parsed != null) {
        state.extensions.set(parsed);
      }
    } catch (_) {
      final reply = state.stanza.firstTag('reply', xmlns: replyXmlns);
      final parentId = (reply?.attributes['id'] ?? '').toString().trim();
      if (parentId.isNotEmpty) {
        final marker = state.stanza.firstTag(
          'peertrans',
          xmlns: peertransXmlns,
        );
        state.extensions.set(
          PeerTransData(
            priority: peertransEffectivePriority(
              marker?.attributes['priority']?.toString(),
            ),
            bodies: const [],
            parentId: parentId,
            parentTo: reply?.attributes['to']?.toString().trim(),
          ),
        );
      }
    }
    return state;
  }
}
