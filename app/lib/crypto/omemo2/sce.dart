// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Minimal XEP-0420 SCE receive helpers for monocles PQ OMEMO2.
// Encrypt path still wraps a plain string today; inbound may be an envelope.

import 'package:moxxmpp/moxxmpp.dart' show XMLNode;

import 'package:resonchat/crypto/omemo2/protocol.dart';

/// Children of SCE `<content/>`, or null when [plaintext] is not an envelope.
///
/// Used after PQ decrypt to reinject destination bodies / langtrans / peertrans
/// onto the outer stanza before extension parsers run.
List<XMLNode>? sceContentChildren(String plaintext) {
  final trimmed = plaintext.trim();
  if (trimmed.isEmpty || !trimmed.contains(sceXmlns)) return null;
  try {
    final root = XMLNode.fromString(trimmed);
    if (root.tag != 'envelope') return null;
    final xmlns = root.attributes['xmlns']?.toString() ?? '';
    if (xmlns != sceXmlns) return null;
    final content =
        root.firstTag('content', xmlns: sceXmlns) ?? root.firstTag('content');
    if (content == null) return null;
    final kids = content.children;
    if (kids.isEmpty) return null;
    return List<XMLNode>.from(kids);
  } catch (_) {
    return null;
  }
}
