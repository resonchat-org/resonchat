// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Carries a B-track (PQ-OMEMO) `<encrypted>` element through moxxmpp's
// stanza pipeline.
//
// moxxmpp's own OMEMO manager only knows the A-track namespace, so the
// B track plugs in as an opaque extension: the outgoing stanza carries both
// elements and only one of them is ours.

import 'package:moxxmpp/moxxmpp.dart';
import 'package:xml/xml.dart';

import 'package:resonchat/crypto/omemo2/message_codec.dart';
import 'package:resonchat/crypto/omemo2/protocol.dart';
import 'package:resonchat/xmpp/encryption/eme.dart';

/// Stanza extension holding a B-track encrypted element.
class PqEncryptedData implements StanzaHandlerExtension {
  const PqEncryptedData(this.message);

  final PqEncryptedMessage message;

  XMLNode toXml() => XMLNode.fromString(message.toXml().toXmlString());
}

/// Serialises the B track's ciphertext and its EME declaration into the
/// outgoing `<message />`.
///
/// Registered with moxxmpp's MessageManager, which only knows how to
/// serialise the extensions it ships with. Without this the ciphertext is
/// dropped and the stanza leaves in plaintext wearing the "encrypted, use
/// another client" body — the worst possible failure, because it looks like
/// it worked.
///
/// Emits nothing when no B-track payload is attached, so A-track and
/// plaintext messages are untouched: moxxmpp's OmemoManager declares their
/// encryption itself.
List<XMLNode> pqSendingCallback(TypedMap<StanzaHandlerExtension> extensions) {
  final payload = extensions.get<PqEncryptedData>();
  if (payload == null) return [];
  final eme = extensions.get<EmeData>();
  return <XMLNode>[
    // Declaration first: a reader scanning the head of the message should
    // learn the track before it hits a blob it cannot read.
    if (eme != null) eme.toXML(),
    payload.toXml(),
  ];
}

/// Finds and parses the B-track `<encrypted>` element in a stanza's XML.
///
/// moxxmpp hands us XMLNode trees rather than `XmlElement`s, so we
/// serialise the subtree and re-parse it with the `xml` package, which is
/// what the codec expects.
PqEncryptedMessage? extractPqPayload(Stanza stanza) {
  for (final child in stanza.children) {
    if (child.tag != 'encrypted') continue;
    if (child.xmlns != omemo2Xmlns) continue;
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
