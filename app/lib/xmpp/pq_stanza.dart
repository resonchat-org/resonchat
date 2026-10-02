// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Carries a B-track (PQ-OMEMO) `<encrypted>` element through moxxmpp's
// stanza pipeline.
//
// moxxmpp's own OMEMO manager only knows the A-track namespace, so the
// B track plugs in as an opaque extension: the outgoing stanza carries both
// elements and only one of them is ours.

import 'package:moxxmpp/moxxmpp.dart';
import 'package:xml/xml.dart';

import '../omemo/message_codec.dart';
import '../omemo/protocol.dart';

/// Stanza extension holding a B-track encrypted element.
class PqEncryptedData implements StanzaHandlerExtension {
  const PqEncryptedData(this.message);

  final PqEncryptedMessage message;

  XMLNode toXml() => XMLNode.fromString(message.toXml().toXmlString());
}

/// Finds and parses the B-track `<encrypted>` element in a stanza's XML.
///
/// moxxmpp hands us XMLNode trees rather than `XmlElement`s, so we
/// serialise the subtree and re-parse it with the `xml` package, which is
/// what the codec expects.
PqEncryptedMessage? extractPqPayload(Stanza stanza) {
  for (final child in stanza.children) {
    if (child.tag != 'encrypted') continue;
    if (child.xmlns != pomemoXmlns) continue;
    try {
      return PqEncryptedMessage.fromXml(
        XmlDocument.parse(child.toXml()).rootElement,
      );
    } catch (_) {
      // Malformed PQ payload: the caller renders "cannot decrypt" rather
      // than dropping the message.
      return null;
    }
  }
  return null;
}