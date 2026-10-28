// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// monocles OMEMO2 outer `<encrypted>` shape (XmppOmemo2Message).
//
// Inner `<key>` text is opaque base64 of a libsignal
// `PreKeySignalMessage` / `SignalMessage` (omemo_dart OMEMO2 stack).

import 'dart:convert';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:xml/xml.dart';

import 'package:resonchat/crypto/omemo2/omemo2_bundle_verify.dart';
import 'package:resonchat/crypto/omemo2/protocol.dart';

final _pqAuthLog = Logger('PqAuth');

/// Content of a `<pq-auth>` element (monocles `XmppOmemo2Message.PqAuthSignature`).
class PqAuthSignature {
  const PqAuthSignature({
    required this.pqIdentityKey,
    required this.pqSignature,
    required this.ikSignature,
  });

  final Uint8List pqIdentityKey;
  final Uint8List pqSignature;
  final Uint8List ikSignature;
}

/// Parse `<pq-auth>`, or null when absent/malformed. Never throws.
PqAuthSignature? parsePqAuth(XmlElement? el) {
  if (el == null) return null;
  try {
    final pqIkEls = el.findElements('pq-ik');
    if (pqIkEls.isEmpty) return null;
    final pqIkEl = pqIkEls.single;
    final type = pqIkEl.getAttribute('type');
    if (type != null && type != omemo2PqIkAlgorithm) {
      _pqAuthLog.warning('OMEMO2: refusing <pq-auth> with type=\'$type\'');
      return null;
    }
    final pqSigEls = el.findElements('pq-sig');
    final ikSigEls = el.findElements('ik-sig');
    if (pqSigEls.isEmpty || ikSigEls.isEmpty) return null;
    final pqIk = base64Decode(pqIkEl.innerText.trim());
    final pqSig = base64Decode(pqSigEls.single.innerText.trim());
    final ikSig = base64Decode(ikSigEls.single.innerText.trim());
    if (pqIk.length != omemo2PqIkLength ||
        pqSig.length != omemo2PqSigLength ||
        ikSig.length != omemo2IkSigLength) {
      _pqAuthLog.warning('OMEMO2: <pq-auth> fields of the wrong length');
      return null;
    }
    return PqAuthSignature(
      pqIdentityKey: Uint8List.fromList(pqIk),
      pqSignature: Uint8List.fromList(pqSig),
      ikSignature: Uint8List.fromList(ikSig),
    );
  } catch (e) {
    _pqAuthLog.warning('OMEMO2: invalid <pq-auth>: $e');
    return null;
  }
}

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
    this.pqAuth,
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

  /// Handshake authentication when any `<key kex='true'>` is present.
  final PqAuthSignature? pqAuth;

  /// Flat list of all key entries (tests / decrypt lookup).
  List<PqKeyEntry> get keys => [for (final r in recipients) ...r.keys];

  /// Whether the header carries at least one pre-key wrap.
  bool get hasKex => keys.any((k) => k.kex);

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
            final auth = pqAuth;
            if (auth != null) {
              builder.element(
                'pq-auth',
                nest: () {
                  builder.element(
                    'pq-ik',
                    attributes: {'type': omemo2PqIkAlgorithm},
                    nest: base64Encode(auth.pqIdentityKey),
                  );
                  builder.element(
                    'pq-sig',
                    nest: base64Encode(auth.pqSignature),
                  );
                  builder.element(
                    'ik-sig',
                    nest: base64Encode(auth.ikSignature),
                  );
                },
              );
            }
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
    final pqAuthEls = header.findElements('pq-auth');
    return PqEncryptedMessage(
      senderDeviceId: int.parse(header.getAttribute('sid')!),
      recipients: recipients,
      payload: el.findElements('payload').single.innerText,
      commit: commitEls.single.innerText,
      pqAuth: pqAuthEls.isEmpty ? null : parsePqAuth(pqAuthEls.first),
    );
  }

  /// Copy with a new [pqAuth] (after signing on the send path).
  PqEncryptedMessage withPqAuth(PqAuthSignature auth) {
    return PqEncryptedMessage(
      senderDeviceId: senderDeviceId,
      recipients: recipients,
      payload: payload,
      commit: commit,
      iv: iv,
      pqAuth: auth,
    );
  }
}

typedef Omemo2EncryptedMessage = PqEncryptedMessage;
