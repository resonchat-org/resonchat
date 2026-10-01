// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// B-track (PQ-OMEMO) protocol constants. See docs/02-protocol-pqomemo.md.

/// Namespace of the PQ track's `<encrypted>` element and EME declaration.
const String pomemoXmlns = 'urn:xmpp:pomemo:0';

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
