// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// B-track `<encrypted>` message codec (docs/02 §5).
//
// Key-exchange messages carry the PQXDH transcript (`ek`, key ids,
// one or two KEM ciphertexts); steady-state messages carry only `wrap`.
// Both wrap the same random 32-byte message key; the payload is one
// AES-256-GCM box under that key.

import 'package:xml/xml.dart';

import 'protocol.dart';

/// Per-recipient-device entry inside `<keys>`.
class PqKeyEntry {
  PqKeyEntry({
    required this.recipientDeviceId,
    required this.wrap,
    this.kex = false,
    this.ek,
    this.spkId,
    this.pkId,
    this.pqSpkId,
    this.pqPkId,
    this.pqCiphertexts = const [],
  });

  final int recipientDeviceId;

  /// The message key, encrypted under this device's session chain key.
  final String wrap;

  /// True on the first message of a session (carries handshake params).
  final bool kex;

  // KEX-only fields (base64 unless noted).
  final String? ek;
  final int? spkId;
  final int? pkId;
  final int? pqSpkId;
  final int? pqPkId;

  /// One (ct1) or two (ct1 + ct2) ML-KEM ciphertexts, base64.
  final List<String> pqCiphertexts;

  /// Appends `<key …>…</key>` to an open builder.
  void buildXml(XmlBuilder builder) {
    builder.element(
      'key',
      attributes: {'rid': '$recipientDeviceId', if (kex) 'kex': 'true'},
      nest: () {
        if (kex) {
          if (ek != null) builder.element('ek', nest: ek);
          if (spkId != null) builder.element('spkid', nest: '$spkId');
          if (pkId != null) builder.element('pkid', nest: '$pkId');
          if (pqSpkId != null) {
            builder.element('pqspkid', nest: '$pqSpkId');
          }
          if (pqPkId != null) builder.element('pqpkid', nest: '$pqPkId');
          for (final ct in pqCiphertexts) {
            builder.element('pqct', nest: ct);
          }
        }
        builder.element('wrap', nest: wrap);
      },
    );
  }

  XmlElement toXml() {
    final builder = XmlBuilder();
    buildXml(builder);
    return builder.buildDocument().rootElement;
  }

  static PqKeyEntry fromXml(XmlElement el) {
    String? one(String tag) => el.findElements(tag).singleOrNull?.innerText;
    int? oneInt(String tag) {
      final v = one(tag);
      return v == null ? null : int.parse(v);
    }

    return PqKeyEntry(
      recipientDeviceId: int.parse(el.getAttribute('rid')!),
      wrap: el.findElements('wrap').single.innerText,
      kex: el.getAttribute('kex') == 'true',
      ek: one('ek'),
      spkId: oneInt('spkid'),
      pkId: oneInt('pkid'),
      pqSpkId: oneInt('pqspkid'),
      pqPkId: oneInt('pqpkid'),
      pqCiphertexts: el.findElements('pqct').map((e) => e.innerText).toList(),
    );
  }
}

/// A full B-track encrypted stanza body.
class PqEncryptedMessage {
  PqEncryptedMessage({
    required this.senderDeviceId,
    required this.keys,
    required this.iv,
    required this.payload,
  });

  final int senderDeviceId;
  final List<PqKeyEntry> keys;

  /// 12-byte IV, base64.
  final String iv;

  /// AES-256-GCM ciphertext + 16-byte tag, base64.
  final String payload;

  XmlElement toXml() {
    final builder = XmlBuilder();
    builder.element(
      'encrypted',
      attributes: {'xmlns': pomemoXmlns},
      nest: () {
        builder.element(
          'header',
          attributes: {'sid': '$senderDeviceId'},
          nest: () {
            builder.element(
              'keys',
              nest: () {
                for (final k in keys) {
                  k.buildXml(builder);
                }
              },
            );
            builder.element('iv', nest: iv);
          },
        );
        builder.element('payload', nest: payload);
      },
    );
    return builder.buildDocument().rootElement;
  }

  static PqEncryptedMessage fromXml(XmlElement el) {
    final header = el.findElements('header').single;
    final keysEl = header.findElements('keys').single;
    return PqEncryptedMessage(
      senderDeviceId: int.parse(header.getAttribute('sid')!),
      keys: keysEl.findElements('key').map(PqKeyEntry.fromXml).toList(),
      iv: header.findElements('iv').single.innerText,
      payload: el.findElements('payload').single.innerText,
    );
  }
}

extension _SingleOrNull on Iterable<XmlElement> {
  XmlElement? get singleOrNull => isEmpty ? null : single;
}
