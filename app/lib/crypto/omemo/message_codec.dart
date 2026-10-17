// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// monocles OMEMO2 outer `<encrypted>` shape (XmppOmemo2Message).
//
// Inner `<key>` text is opaque base64 of a libsignal
// `PreKeySignalMessage` / `SignalMessage` (omemo_dart OMEMO2 stack).

import 'dart:convert';
import 'dart:typed_data';

import 'package:xml/xml.dart';

import 'protocol.dart';

/// Per-recipient-device entry: SessionCipher ciphertext for the 32-byte MK.
class PqKeyEntry {
  PqKeyEntry({
    required this.recipientDeviceId,
    required this.ciphertext,
    this.kex = false,
  });

  final int recipientDeviceId;

  /// Base64 of serialized PreKeySignalMessage / SignalMessage.
  final String ciphertext;

  /// True when [ciphertext] is a PreKeySignalMessage (`kex="true"`).
  final bool kex;

  /// Alias used by older call sites / tests.
  String get wrap => ciphertext;

  String toWireCiphertext() => ciphertext;

  static PqKeyEntry fromWire({
    required int rid,
    required String ciphertext,
    bool kexAttr = false,
  }) {
    return PqKeyEntry(
      recipientDeviceId: rid,
      ciphertext: ciphertext.trim(),
      kex: kexAttr,
    );
  }

  void buildXml(XmlBuilder builder) {
    builder.element(
      'key',
      attributes: {'rid': '$recipientDeviceId', if (kex) 'kex': 'true'},
      nest: toWireCiphertext(),
    );
  }

  XmlElement toXml() {
    final builder = XmlBuilder();
    buildXml(builder);
    return builder.buildDocument().rootElement;
  }

  static PqKeyEntry fromXml(XmlElement el) {
    return fromWire(
      rid: int.parse(el.getAttribute('rid')!),
      ciphertext: el.innerText.trim(),
      kexAttr: el.getAttribute('kex') == 'true',
    );
  }
}

/// Keys for one bare JID.
class Omemo2KeysForJid {
  Omemo2KeysForJid({required this.jid, required this.keys});

  final String jid;
  final List<PqKeyEntry> keys;

  void buildXml(XmlBuilder builder) {
    builder.element(
      'keys',
      attributes: {'jid': jid},
      nest: () {
        for (final k in keys) {
          k.buildXml(builder);
        }
      },
    );
  }

  static Omemo2KeysForJid fromXml(XmlElement el) {
    return Omemo2KeysForJid(
      jid: el.getAttribute('jid') ?? '',
      keys: el.findElements('key').map(PqKeyEntry.fromXml).toList(),
    );
  }
}

/// Full OMEMO2 encrypted element.
class PqEncryptedMessage {
  PqEncryptedMessage({
    required this.senderDeviceId,
    required this.payload,
    required this.commit,
    List<Omemo2KeysForJid>? recipients,
    List<PqKeyEntry>? keys,
    this.iv = '',
  }) : recipients =
           recipients ??
           (keys != null
               ? [Omemo2KeysForJid(jid: '', keys: keys)]
               : <Omemo2KeysForJid>[]);

  final int senderDeviceId;
  final List<Omemo2KeysForJid> recipients;

  /// AES-256-GCM ciphertext‖tag, base64.
  final String payload;

  /// 64-byte key commitment, base64.
  final String commit;

  /// Legacy field; unused when KMAC derives the IV.
  final String iv;

  /// Flat list of all key entries (tests / decrypt lookup).
  List<PqKeyEntry> get keys => [for (final r in recipients) ...r.keys];

  XmlElement toXml() {
    final builder = XmlBuilder();
    builder.element(
      'encrypted',
      attributes: {'xmlns': omemo2Xmlns},
      nest: () {
        builder.element(
          'header',
          attributes: {'sid': '$senderDeviceId'},
          nest: () {
            for (final r in recipients) {
              r.buildXml(builder);
            }
          },
        );
        builder.element('payload', nest: payload);
        builder.element('commit', nest: commit);
      },
    );
    return builder.buildDocument().rootElement;
  }

  static PqEncryptedMessage fromXml(XmlElement el) {
    final header = el.findElements('header').single;
    final commitEls = el.findElements('commit');
    if (commitEls.isEmpty) {
      throw FormatException('OMEMO2 message missing mandatory <commit>');
    }
    final keysGroups = header.findElements('keys').toList();
    final recipients = keysGroups.isEmpty
        ? <Omemo2KeysForJid>[]
        : keysGroups.map(Omemo2KeysForJid.fromXml).toList();
    return PqEncryptedMessage(
      senderDeviceId: int.parse(header.getAttribute('sid')!),
      recipients: recipients,
      payload: el.findElements('payload').single.innerText,
      commit: commitEls.single.innerText,
    );
  }
}

typedef Omemo2EncryptedMessage = PqEncryptedMessage;

/// Context binding for KMAC / GCM AAD (proto-XEP §5.4.2).
Uint8List omemo2ContextBinding({
  required String senderBareJid,
  required String recipientBareJid,
  required int sourceDeviceId,
}) {
  final b = BytesBuilder(copy: false);
  b.add(utf8.encode('OMEMO2'));
  b.addByte(0);
  b.add(utf8.encode(senderBareJid));
  b.addByte(0);
  b.add(utf8.encode(recipientBareJid));
  b.addByte(0);
  final sid = ByteData(4)..setUint32(0, sourceDeviceId, Endian.big);
  b.add(sid.buffer.asUint8List());
  return b.toBytes();
}
