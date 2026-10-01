// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// B-track bundle model + XML codec (docs/02 §4).
//
// The bundle carries the classic A-track keys alongside the PQ keys so a
// single PEP item serves both tracks; standard clients simply ignore the
// unknown `pq*` elements.

import 'dart:convert';

import 'package:xml/xml.dart';

import 'protocol.dart';

/// One device's publishable B-track bundle.
class PqBundle {
  PqBundle({
    required this.deviceId,
    required this.spk,
    required this.spkSignature,
    required this.prekeys,
    required this.pqSpkId,
    required this.pqSpk,
    required this.pqSpkSignature,
    required this.pqPrekeys,
  });

  final int deviceId;

  // Classic (A-track) part, base64.
  final String spk;
  final String spkSignature;
  final Map<int, String> prekeys;

  // PQ part, base64. ML-KEM-768 pk = 1184 bytes.
  final int pqSpkId;
  final String pqSpk;
  final String pqSpkSignature;
  final Map<int, String> pqPrekeys;

  /// True when the PQ section is usable for handshakes.
  bool get hasPqKeys => pqSpk.isNotEmpty;

  XmlElement toXml() {
    final builder = XmlBuilder();
    builder.element(
      'bundle',
      attributes: {'xmlns': pomemoXmlns, 'device': '$deviceId'},
      nest: () {
        builder.element('spk', nest: spk);
        builder.element('spsk', nest: spkSignature);
        builder.element('prekeys', nest: () {
          for (final entry in prekeys.entries) {
            builder.element('pk',
                attributes: {'id': '${entry.key}'}, nest: entry.value);
          }
        });
        builder.element('pqspk',
            attributes: {'id': '$pqSpkId'}, nest: pqSpk);
        builder.element('pqspks', nest: pqSpkSignature);
        builder.element('pqprekeys', nest: () {
          for (final entry in pqPrekeys.entries) {
            builder.element('pqpk',
                attributes: {'id': '${entry.key}'}, nest: entry.value);
          }
        });
      },
    );
    return builder.buildDocument().rootElement;
  }

  static PqBundle fromXml(XmlElement el) {
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

    final pqSpkEls = el.findElements('pqspk');
    return PqBundle(
      deviceId: int.parse(el.getAttribute('device')!),
      spk: one('spk'),
      spkSignature: one('spsk'),
      prekeys: keyMap('prekeys', 'pk'),
      pqSpkId: pqSpkEls.isEmpty
          ? -1
          : int.parse(pqSpkEls.single.getAttribute('id')!),
      pqSpk: pqSpkEls.isEmpty ? '' : pqSpkEls.single.innerText,
      pqSpkSignature: el.findElements('pqspks').singleOrNull?.innerText ?? '',
      pqPrekeys: keyMap('pqprekeys', 'pqpk'),
    );
  }

  /// Encodes raw bytes for transport fields.
  static String b64(List<int> bytes) => base64Encode(bytes);

  /// Decodes a transport field back to bytes.
  static List<int> unb64(String s) => base64Decode(s);
}

extension _SingleOrNull on Iterable<XmlElement> {
  XmlElement? get singleOrNull => isEmpty ? null : single;
}
