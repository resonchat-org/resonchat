// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// monocles OMEMO2 bundle model + XML codec (proto-XEP §4.3 / IqGenerator).

import 'dart:convert';
import 'dart:typed_data';

import 'package:xml/xml.dart';

import 'protocol.dart';

/// One device's publishable OMEMO2 bundle.
class Omemo2Bundle {
  Omemo2Bundle({
    required this.deviceId,
    required this.jid,
    required this.spk,
    required this.spkId,
    required this.spkSignature,
    required this.ik,
    required this.prekeys,
    required this.kemSpkId,
    required this.kemSpk,
    required this.kemSpkSignature,
    required this.kemPrekeys,
    required this.kemPrekeySignatures,
    required this.pqIk,
    required this.pqSig,
  });

  final int deviceId;
  final String jid;

  /// EC signed prekey, base64 of **raw 32-byte** Curve25519 public key.
  final String spk;
  final int spkId;

  /// Ed25519 signature over SPK (base64).
  final String spkSignature;

  /// Classical identity public key, base64 of **raw 32-byte** (no 0x05).
  final String ik;

  /// One-time EC prekeys: id → base64 raw 32-byte public.
  final Map<int, String> prekeys;

  final int kemSpkId;

  /// ML-KEM-1024 last-resort public key, base64 of libsignal serialize
  /// (`0x0A ‖ pk`).
  final String kemSpk;
  final String kemSpkSignature;

  /// One-time KEM prekeys: id → base64 tagged public key.
  final Map<int, String> kemPrekeys;

  /// Per-OPK Ed25519 signatures (same ids as [kemPrekeys]).
  final Map<int, String> kemPrekeySignatures;

  /// ML-DSA-87 identity public key, base64 raw 2592 bytes.
  final String pqIk;

  /// ML-DSA-87 signature over the identity transcript, base64.
  final String pqSig;

  bool get hasPqIdentity => pqIk.isNotEmpty && pqSig.isNotEmpty;

  XmlElement toXml() {
    final builder = XmlBuilder();
    builder.element(
      'bundle',
      attributes: {
        'xmlns': omemo2Xmlns,
        // PEP item id is authoritative, but set the attribute too so a fetch
        // that only sees the payload still recovers the device id.
        if (deviceId != 0) 'device': '$deviceId',
      },
      nest: () {
        builder.element('spk', attributes: {'id': '$spkId'}, nest: spk);
        builder.element('spks', nest: spkSignature);
        builder.element('ik', nest: ik);
        builder.element(
          'prekeys',
          nest: () {
            for (final e in prekeys.entries) {
              builder.element(
                'pk',
                attributes: {'id': '${e.key}'},
                nest: e.value,
              );
            }
          },
        );
        builder.element(
          'kem-spk',
          attributes: {'id': '$kemSpkId'},
          nest: kemSpk,
        );
        builder.element('kem-spks', nest: kemSpkSignature);
        builder.element(
          'kem-prekeys',
          nest: () {
            for (final e in kemPrekeys.entries) {
              builder.element(
                'kem-pk',
                attributes: {
                  'id': '${e.key}',
                  'sig': kemPrekeySignatures[e.key] ?? '',
                },
                nest: e.value,
              );
            }
          },
        );
        builder.element(
          'pq-ik',
          attributes: {'type': omemo2PqIkAlgorithm},
          nest: pqIk,
        );
        builder.element('pq-sig', nest: pqSig);
      },
    );
    return builder.buildDocument().rootElement;
  }

  /// Parses a published `<bundle/>`.
  ///
  /// [deviceId] is the PEP item id used to fetch the bundle — that is the
  /// authoritative device id (monocles / Conversations). The optional
  /// `device` XML attribute is only a fallback when the caller did not pass
  /// the item id.
  static Omemo2Bundle fromXml(
    XmlElement el, {
    String? jidOfBundle,
    int? deviceId,
  }) {
    String one(String tag) => el.findElements(tag).single.innerText;

    Map<int, String> keyMap(String parent, String child) {
      final out = <int, String>{};
      for (final section in el.findElements(parent)) {
        for (final k in section.findElements(child)) {
          out[int.parse(k.getAttribute('id')!)] = k.innerText;
        }
      }
      return out;
    }

    final kemSigs = <int, String>{};
    final kemPks = <int, String>{};
    for (final section in el.findElements('kem-prekeys')) {
      for (final k in section.findElements('kem-pk')) {
        final id = int.parse(k.getAttribute('id')!);
        kemPks[id] = k.innerText;
        kemSigs[id] = k.getAttribute('sig') ?? '';
      }
    }

    final spkEl = el.findElements('spk').single;
    final kemSpkEl = el.findElements('kem-spk').single;
    final pqIkEl = el.findElements('pq-ik').single;
    final pqType = pqIkEl.getAttribute('type');
    if (pqType != null && pqType.isNotEmpty && pqType != omemo2PqIkAlgorithm) {
      throw FormatException('unsupported pq-ik type: $pqType');
    }

    final deviceAttr = el.getAttribute('device');
    final fromAttr = deviceAttr == null ? null : int.tryParse(deviceAttr);
    final resolvedId = deviceId ?? fromAttr ?? 0;
    if (resolvedId == 0) {
      throw FormatException(
        'OMEMO2 bundle missing device id (pass PEP item id into fromXml)',
      );
    }

    return Omemo2Bundle(
      deviceId: resolvedId,
      jid: jidOfBundle ?? '',
      spk: spkEl.innerText,
      spkId: int.parse(spkEl.getAttribute('id')!),
      spkSignature: one('spks'),
      ik: one('ik'),
      prekeys: keyMap('prekeys', 'pk'),
      kemSpkId: int.parse(kemSpkEl.getAttribute('id')!),
      kemSpk: kemSpkEl.innerText,
      kemSpkSignature: one('kem-spks'),
      kemPrekeys: kemPks,
      kemPrekeySignatures: kemSigs,
      pqIk: pqIkEl.innerText,
      pqSig: one('pq-sig'),
    );
  }

  /// Raw 32-byte identity public key bytes.
  Uint8List get ikBytes => base64Decode(ik);

  /// Classical IdentityKey.serialize() form (0x05 ‖ 32).
  Uint8List get ikSerialized => Uint8List.fromList([0x05, ...ikBytes]);
}

/// @Deprecated Use [Omemo2Bundle].
typedef PqBundle = Omemo2Bundle;
