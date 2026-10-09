// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// B-track (PQ-OMEMO) protocol constants. See docs/02-protocol-pqomemo.md.

import 'package:moxxmpp/moxxmpp.dart' show emePomemo0;

/// Namespace of the PQ track's `<encrypted>` element and EME declaration.
///
/// Aliased from the one place the value is written down — moxxmpp's
/// namespace table, which is also what the EME mapping reads. Two
/// independent declarations of one namespace is exactly how a client ends up
/// writing `urn:xmpp:pomemo:0` on the wire and then refusing to recognise it
/// on the way back in.
const String pomemoXmlns = emePomemo0;

/// PEP node carrying the B-track device list.
const String pomemoDevicesXmlns = 'urn:xmpp:pomemo:0:devices';

/// PEP node carrying per-device B-track bundles.
const String pomemoBundlesXmlns = 'urn:xmpp:pomemo:0:bundles';

/// EME `name` shown by supporting clients for the B track.
const String pomemoEmeName = 'OMEMO-PQ';

/// Body fallback shown by clients that cannot decrypt either track.
const String encryptedBodyFallback =
    'This message is encrypted. Use a supported client to read it.';

/// Per-chat encryption mode (docs/02 §6).
enum EncMode {
  /// Cannot encrypt to all devices (or no devices known).
  none,

  /// Standard OMEMO interop track.
  standardOmemo,

  /// Post-quantum hybrid track.
  pqOmemo,
}

/// Short UI label for [mode], without emoji (icons draw the lock).
String encModeLabel(EncMode mode) => switch (mode) {
  EncMode.pqOmemo => 'PQ',
  EncMode.standardOmemo => 'OMEMO',
  EncMode.none => 'Unencrypted',
};
