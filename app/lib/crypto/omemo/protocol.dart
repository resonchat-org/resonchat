// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// monocles PQ-OMEMO2 protocol constants (`urn:monocles:omemo-pq:1`).
// Spec: references/monocles_chat/docs/proto-xep-omemo-pqxdh.md

/// Namespace of OMEMO2 `<encrypted>`, `<bundle>`, and `<devices>` *payloads*.
///
/// Deliberately not `urn:xmpp:omemo:2` — monocles chose a distinct NS so
/// classical XEP-0384 v0.9 clients ignore these bundles.
///
/// monocles `Namespace.OMEMO2`: the element xmlns is this base URI. The PEP
/// *node names* are the `:devices` / `:bundles` suffixes below — do not put
/// those suffixes on the `<devices>` element itself or monocles will miss
/// the list (`findChild("devices", Namespace.OMEMO2)`).
const String omemo2Xmlns = 'urn:monocles:omemo-pq:1';

/// PEP node name for the OMEMO2 device list (not the payload xmlns).
const String omemo2DevicesXmlns = '$omemo2Xmlns:devices';

/// PEP node name for per-device OMEMO2 bundles (not the payload xmlns).
const String omemo2BundlesXmlns = '$omemo2Xmlns:bundles';

/// Disco feature for PQXDH capability advertisement (diagnostics only).
const String omemo2PqxdhFeature = '$omemo2Xmlns:pqxdh';

/// EME `name` shown by supporting clients.
const String omemo2EmeName = 'PQ OMEMO2';

/// SCE envelope namespace (XEP-0420).
const String sceXmlns = 'urn:xmpp:sce:1';

/// Body fallback shown by clients that cannot decrypt either track.
const String encryptedBodyFallback =
    'This message is encrypted. Use a supported client to read it.';

/// KMAC customization string for payload key/IV derivation (proto-XEP §5.4).
const String omemo2PayloadKmacLabel = 'monocles:omemo2:payload:v3';

/// KMAC customization string for key commitment (proto-XEP §5.5).
const String omemo2CommitKmacLabel = 'monocles:omemo2:key-commitment:v3';

/// ML-DSA-87 FIPS-204 signing context for `<pq-sig>` (proto-XEP §4.9).
const String omemo2PqIdContext = 'monocles:omemo2:pqid:v1';

/// Identity transcript domain label (proto-XEP §4.9.1).
const String omemo2PqBundleTranscriptLabel = 'monocles:omemo2:pq-bundle:v3';

/// KEM binding domain label (proto-XEP §4.9.1).
const String omemo2KemBindingLabel = 'monocles:omemo2:kem-binding:v2';

/// Fixed algorithm identifiers bound into the signed transcript.
const String omemo2PqIkAlgorithm = 'ML-DSA-87';
const String omemo2KemAlgorithm = 'ML-KEM-1024';

/// libsignal ML-KEM-1024 public-key type tag (proto-XEP / CryptoHelper).
const int mlKem1024Tag = 0x0A;

/// Round-3 Kyber-1024 tag — must be refused.
const int kyber1024Round3Tag = 0x08;

// ---------------------------------------------------------------------------
// Backward-compatible aliases (old pomemo names → monocles OMEMO2).
// ---------------------------------------------------------------------------

@Deprecated('Use omemo2Xmlns')
const String pomemoXmlns = omemo2Xmlns;

@Deprecated('Use omemo2DevicesXmlns')
const String pomemoDevicesXmlns = omemo2DevicesXmlns;

@Deprecated('Use omemo2BundlesXmlns')
const String pomemoBundlesXmlns = omemo2BundlesXmlns;

@Deprecated('Use omemo2EmeName')
const String pomemoEmeName = omemo2EmeName;

/// Per-chat encryption mode (docs/02 §6).
enum EncMode {
  /// Cannot encrypt to all devices (or no devices known).
  none,

  /// Standard OMEMO interop track (Conversations / legacy).
  standardOmemo,

  /// monocles PQ-OMEMO2 track.
  pqOmemo,
}

/// Short UI label for [mode], without emoji (icons draw the lock).
String encModeLabel(EncMode mode) => switch (mode) {
  EncMode.pqOmemo => 'OMEMO2',
  EncMode.standardOmemo => 'OMEMO',
  EncMode.none => 'Unencrypted',
};
