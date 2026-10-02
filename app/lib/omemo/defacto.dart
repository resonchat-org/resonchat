// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The two OMEMO wire dialects.
//
// XEP-0384 v2 specifies node names `urn:xmpp:omemo:2:devices` /
// `:bundles` and elements `<spk>`, `<spks>`, `<ik>`, `<prekeys><pk/>`.
// No mainstream client ever implemented those. Conversations, Signal and
// everything else ship the "Secret Omemo Device List" from the Signal
// iOS/Android fork, renamed:
//
//   node  eu.siacs.conversations.axolotl.devicelist
//   node  eu.siacs.conversations.axolotl.bundles:<deviceId>
//   xmlns eu.siacs.conversations.axolotl
//   <list><device id/></list>
//   <bundle><signedPreKeyPublic signedPreKeyId/>
//           <signedPreKeySignature/><identityKey/>
//           <prekeys><preKeyPublic preKeyId/></prekeys></bundle>
//
// This was measured against a live server while installing the real
// Conversations 2.20.4 (see integration_test/m2_interop_test.dart): asking
// for `urn:xmpp:omemo:2:bundles:<id>` returns `<item-not-found/>`, while
// the axolotl node returns a perfectly good bundle.
//
// Being spec-correct and being interoperable are different things. We
// therefore *speak both*: publishing writes the de-facto dialect so real
// clients can read us, plus the spec dialect for any client that ever
// adopts it; reading accepts either.

import 'dart:convert';

import 'package:omemo_dart/omemo_dart.dart' show OmemoBundle;
import 'package:xml/xml.dart';

/// PEP node carrying Conversations' OMEMO device list.
const String omemoDefactoDevicesNode =
    'eu.siacs.conversations.axolotl.devicelist';

/// PEP node prefix for Conversations' per-device bundles. The full node is
/// this plus the device id.
const String omemoDefactoBundlesNode =
    'eu.siacs.conversations.axolotl.bundles';

/// Namespace of the de-facto bundle and device-list payloads.
const String omemoDefactoXmlns = 'eu.siacs.conversations.axolotl';

/// The XEP-0384 v2 node names, published and read as well.
const List<String> omemoSpecDevicesNodes = <String>[
  'urn:xmpp:omemo:2:devices',
];

const List<String> omemoSpecBundlesNodes = <String>[
  'urn:xmpp:omemo:2:bundles',
];

/// Serialises [bundle] in the de-facto dialect.
XmlElement bundleToDefactoXml(OmemoBundle bundle) {
  final builder = XmlBuilder();
  builder.element(
    'bundle',
    attributes: {'xmlns': omemoDefactoXmlns},
    nest: () {
      builder.element(
        'signedPreKeyPublic',
        attributes: {'signedPreKeyId': '${bundle.spkId}'},
        nest: addKeyTypeByte(bundle.spkEncoded),
      );
      builder.element(
        'signedPreKeySignature',
        nest: bundle.spkSignatureEncoded,
      );
      builder.element('identityKey', nest: addKeyTypeByte(bundle.ikEncoded));
      builder.element('prekeys', nest: () {
        for (final e in bundle.opksEncoded.entries) {
          builder.element(
            'preKeyPublic',
            attributes: {'preKeyId': '${e.key}'},
            nest: addKeyTypeByte(e.value),
          );
        }
      });
    },
  );
  return builder.buildDocument().rootElement;
}

/// Signal serialises a public key as a one-byte type prefix followed by the
/// 32-byte key. omemo_dart stores and expects the bare 32 bytes, so the two
/// representations must be translated at this boundary.
///
/// Measured against Conversations 2.20.4: its bundle carried 33-byte spk,
/// ik and every prekey, with a 64-byte signature. Feeding those 33 bytes to
/// the ratchet as-is would mix the type byte into the key material and
/// break the DH silently; publishing ours without the prefix makes every
/// real client reject the bundle outright.
const int keyTypePrefix = 0x05;

/// Removes Signal's key-type prefix when present.
String stripKeyTypeByte(String b64) {
  final bytes = base64Decode(b64);
  if (bytes.length == 33 && bytes.first == keyTypePrefix) {
    return base64Encode(bytes.sublist(1));
  }
  return b64;
}

/// Adds Signal's key-type prefix unless it is already present.
String addKeyTypeByte(String b64) {
  final bytes = base64Decode(b64);
  if (bytes.length == 33) return b64;
  return base64Encode([keyTypePrefix, ...bytes]);
}

/// Serialises the device list payload in the de-facto dialect.
XmlElement deviceListToDefactoXml(Iterable<int> deviceIds) {
  final builder = XmlBuilder();
  builder.element(
    'list',
    attributes: {'xmlns': omemoDefactoXmlns},
    nest: () {
      for (final id in deviceIds) {
        builder.element('device', attributes: {'id': '$id'});
      }
    },
  );
  return builder.buildDocument().rootElement;
}

/// Parses a bundle in either dialect.
///
/// Throws [FormatException] when a required element is absent, so callers
/// can treat the result as "this device cannot be read" instead of crashing.
OmemoBundle parseOmemoBundle(
  XmlElement el, {
  required String jid,
  required int deviceId,
}) {
  if (el.localName != 'bundle') {
    throw FormatException('not a bundle element: ${el.localName}');
  }

  // The two dialects disagree on every element name, so look each one up
  // under both spellings.
  String text(List<String> names) {
    for (final name in names) {
      final found = el.findElements(name);
      if (found.isNotEmpty) return found.first.innerText;
    }
    throw FormatException('bundle has none of ${names.join("/")}');
  }

  String? attributeOf(List<String> names, List<String> attrNames) {
    for (final name in names) {
      final found = el.findElements(name);
      if (found.isEmpty) continue;
      for (final attr in attrNames) {
        final value = found.first.getAttribute(attr);
        if (value != null) return value;
      }
    }
    return null;
  }

  final opks = <int, String>{};
  for (final section in el.findElements('prekeys')) {
    for (final child in section.childElements) {
      // `pk` with `id`, or `preKeyPublic` with `preKeyId`.
      final idText = child.getAttribute('id') ?? child.getAttribute('preKeyId');
      final id = int.tryParse(idText ?? '');
      if (id == null) continue;
      opks[id] = child.innerText;
    }
  }

  final spkIdText = attributeOf(
    const ['spk', 'signedPreKeyPublic'],
    const ['id', 'signedPreKeyId'],
  );
  if (spkIdText == null) {
    throw const FormatException('signed prekey has no id');
  }

  return OmemoBundle(
    jid,
    deviceId,
    stripKeyTypeByte(text(const ['spk', 'signedPreKeyPublic'])),
    int.parse(spkIdText),
    // The signature is raw Ed25519 and carries no prefix.
    text(const ['spks', 'spsk', 'signedPreKeySignature']),
    stripKeyTypeByte(text(const ['ik', 'identityKey'])),
    {
      for (final e in opks.entries) e.key: stripKeyTypeByte(e.value),
    },
  );
}

/// Parses a device list payload in either dialect.
///
/// Returns null when the element carries no `<device>` children, which the
/// server uses for "no devices".
Set<int>? parseOmemoDeviceList(XmlElement el) {
  // `devices` (spec) or `list` (de-facto); children are `<device id/>` in
  // both.
  if (el.localName != 'devices' && el.localName != 'list') return null;
  final ids = <int>{};
  for (final child in el.findElements('device')) {
    final id = int.tryParse('${child.getAttribute('id')}');
    if (id != null) ids.add(id);
  }
  return ids;
}

/// Structural sanity check shared by tests and the interop probe.
bool omemoBundleLooksSane(OmemoBundle b) {
  try {
    if (base64Decode(b.spkEncoded).length != 32) return false;
    if (base64Decode(b.spkSignatureEncoded).length != 64) return false;
    if (base64Decode(b.ikEncoded).length != 32) return false;
    if (b.opksEncoded.isEmpty) return false;
    for (final pk in b.opksEncoded.values) {
      if (base64Decode(pk).length != 32) return false;
    }
    return true;
  } catch (_) {
    return false;
  }
}