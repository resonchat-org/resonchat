// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Outgoing XEP-0380 (EME) declaration.
//
// The label under a message has to survive the trip: a receiver — this app
// or any other — must be able to say which track a message used without
// decrypting it. EME is the only standard way to carry that.
//
// moxxmpp's EmeManager reads these elements but never writes them, so the
// outgoing half lives here. It is a stanza extension rather than a raw XML
// node because moxxmpp assembles messages from extensions.

import 'package:moxxmpp/moxxmpp.dart';

import 'package:resonchat/crypto/dual/track.dart';

/// Declares the encryption used on an outgoing message.
///
/// Only ever construct this for a message that *is* encrypted. A plaintext
/// message declares nothing: an EME element with an empty namespace would be
/// worse than silence, because it reads as a claim we cannot back up.
class EmeData implements StanzaHandlerExtension {
  const EmeData(this.track, {this.name})
    : assert(
        track != Track.none,
        'a plaintext message must not carry an encryption declaration',
      );

  /// The track actually applied to the message.
  ///
  /// Not the track the user selected: if encryption failed and we fell back,
  /// this must say what went out, or the label under the bubble is a lie.
  final Track track;

  /// Human-readable name for clients that do not know the namespace.
  final String? name;

  /// moxxmpp calls this by convention; the marker interface has no members.
  XMLNode toXML() {
    return XMLNode.xmlns(
      tag: 'encryption',
      xmlns: emeXmlns,
      attributes: <String, String>{
        'namespace': track.emeNamespace!,
        if (name != null && name!.isNotEmpty) 'name': name!,
      },
    );
  }
}
