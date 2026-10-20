// Copyright (C) 2026 ResonChat contributors.
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

/// `<pq-ik type>` on the bundle element. KMAC labels and the ML-DSA context
/// live next to the seal in omemo_dart.
const String omemo2PqIkAlgorithm = 'ML-DSA-87';

/// Diagnostic `rev` on published `<bundle/>` (monocles `OMEMO2_BUNDLE_REVISION`).
///
/// Unsigned — does not select behaviour. Monocles logs it when `<ik-sig>` is
/// missing so the peer knows to update.
const String omemo2BundleRevision = '4';

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
