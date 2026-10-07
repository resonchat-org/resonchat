// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The two OMEMO wire dialects for PEP discovery.
//
// A-track crypto is Conversations axolotl (OMEMO 0.3.0). Bundle key material
// is libsignal serialize() output (33-byte public keys with 0x05 prefix).

import 'dart:convert';

import 'package:omemo_dart/omemo_dart_axolotl.dart';
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

/// Signal public-key type byte (Curve25519).
const int keyTypePrefix = 0x05;

/// Ensures [b64] carries the 0x05 type prefix (idempotent).
String ensureKeyTypeByte(String b64) {
  final bytes = base64Decode(b64);
  if (bytes.length == 33 && bytes.first == keyTypePrefix) return b64;
  if (bytes.length == 32) {
    return base64Encode([keyTypePrefix, ...bytes]);
  }
  return b64;
}

/// Serialises [bundle] in the de-facto Conversations dialect.
XmlElement bundleToDefactoXml(AxolotlBundle bundle) {
  final builder = XmlBuilder();
  builder.element(
    'bundle',
    attributes: {'xmlns': omemoDefactoXmlns},
    nest: () {
      builder.element(
        'signedPreKeyPublic',
        attributes: {'signedPreKeyId': '${bundle.signedPreKeyId}'},
        nest: ensureKeyTypeByte(bundle.signedPreKeyPublicEncoded),
      );
      builder.element(
        'signedPreKeySignature',
        nest: bundle.signedPreKeySignatureEncoded,
      );
      builder.element(
        'identityKey',
        nest: ensureKeyTypeByte(bundle.identityKeyEncoded),
      );
      builder.element('prekeys', nest: () {
        for (final e in bundle.preKeysEncoded.entries) {
          builder.element(
            'preKeyPublic',
            attributes: {'preKeyId': '${e.key}'},
            nest: ensureKeyTypeByte(e.value),
          );
        }
      });
    },
  );
  return builder.buildDocument().rootElement;
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

/// Parses a bundle in either dialect into an [AxolotlBundle].
///
/// Keys keep the Signal type byte when present; bare 32-byte keys are
/// accepted and prefixed so libsignal can decode them.
AxolotlBundle parseOmemoBundle(
  XmlElement el, {
  required String jid,
  required int deviceId,
}) {
  if (el.localName != 'bundle') {
    throw FormatException('not a bundle element: ${el.localName}');
  }

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
      final idText = child.getAttribute('id') ?? child.getAttribute('preKeyId');
      final id = int.tryParse(idText ?? '');
      if (id == null) continue;
      opks[id] = ensureKeyTypeByte(child.innerText);
    }
  }

  final spkIdText = attributeOf(
    const ['spk', 'signedPreKeyPublic'],
    const ['id', 'signedPreKeyId'],
  );
  if (spkIdText == null) {
    throw const FormatException('signed prekey has no id');
  }

  return AxolotlBundle(
    jid: jid,
    deviceId: deviceId,
    signedPreKeyId: int.parse(spkIdText),
    signedPreKeyPublicEncoded:
        ensureKeyTypeByte(text(const ['spk', 'signedPreKeyPublic'])),
    signedPreKeySignatureEncoded:
        text(const ['spks', 'spsk', 'signedPreKeySignature']),
    identityKeyEncoded:
        ensureKeyTypeByte(text(const ['ik', 'identityKey'])),
    preKeysEncoded: opks,
    registrationId: deviceId,
  );
}

/// Parses a device list payload in either dialect.
Set<int>? parseOmemoDeviceList(XmlElement el) {
  if (el.localName != 'devices' && el.localName != 'list') return null;
  final ids = <int>{};
  for (final child in el.findElements('device')) {
    final id = int.tryParse('${child.getAttribute('id')}');
    if (id != null) ids.add(id);
  }
  return ids;
}

/// Structural sanity check for an axolotl bundle.
bool omemoBundleLooksSane(AxolotlBundle b) {
  try {
    final spk = base64Decode(b.signedPreKeyPublicEncoded);
    final ik = base64Decode(b.identityKeyEncoded);
    final sig = base64Decode(b.signedPreKeySignatureEncoded);
    if (spk.length != 33 && spk.length != 32) return false;
    if (ik.length != 33 && ik.length != 32) return false;
    if (sig.length != 64) return false;
    if (b.preKeysEncoded.isEmpty) return false;
    for (final pk in b.preKeysEncoded.values) {
      final len = base64Decode(pk).length;
      if (len != 33 && len != 32) return false;
    }
    return true;
  } catch (_) {
    return false;
  }
}

/// Legacy aliases kept for call sites that still use the old names.
String stripKeyTypeByte(String b64) {
  final bytes = base64Decode(b64);
  if (bytes.length == 33 && bytes.first == keyTypePrefix) {
    return base64Encode(bytes.sublist(1));
  }
  return b64;
}

String addKeyTypeByte(String b64) => ensureKeyTypeByte(b64);
