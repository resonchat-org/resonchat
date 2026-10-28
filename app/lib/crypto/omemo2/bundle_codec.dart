// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// monocles OMEMO2 bundle model + XML codec (proto-XEP §4.3 / IqGenerator).

import 'dart:convert';
import 'dart:typed_data';

import 'package:xml/xml.dart';

import 'package:resonchat/crypto/omemo2/protocol.dart';

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
    required this.ikSig,
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

  /// Classical IK XEdDSA signature over the same transcript (`<ik-sig>`).
  ///
  /// Mandatory for monocles: without it peers log "predates bundle transcript
  /// v4" and refuse the OMEMO2 session — so fingerprints never appear.
  final String ikSig;

  /// monocles `IqParser.omemo2PqIdentity`: all three halves required.
  bool get hasPqIdentity =>
      pqIk.isNotEmpty && pqSig.isNotEmpty && ikSig.isNotEmpty;

  XmlElement toXml() {
    final builder = XmlBuilder();
    builder.element(
      'bundle',
      attributes: {
        'xmlns': omemo2Xmlns,
        'rev': omemo2BundleRevision,
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
        builder.element('ik-sig', nest: ikSig);
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
    // Local name, any namespace. monocles publishes under the default
    // `urn:monocles:omemo-pq:1` xmlns; a prefix must not hide the children.
    Iterable<XmlElement> kids(XmlElement parent, String tag) =>
        parent.findElements(tag, namespace: '*');

    String one(String tag) => omemo2WireB64(kids(el, tag).single.innerText);

    Map<int, String> keyMap(String parent, String child) {
      final out = <int, String>{};
      for (final section in kids(el, parent)) {
        for (final k in kids(section, child)) {
          out[int.parse(k.getAttribute('id')!)] = omemo2WireB64(k.innerText);
        }
      }
      return out;
    }

    // Document order, not id order — the KEM binding manifest hashes this
    // sequence (monocles `omemo2KemPreKeys`).
    final kemSigs = <int, String>{};
    final kemPks = <int, String>{};
    for (final section in kids(el, 'kem-prekeys')) {
      for (final k in kids(section, 'kem-pk')) {
        final id = int.parse(k.getAttribute('id')!);
        kemPks[id] = omemo2WireB64(k.innerText);
        kemSigs[id] = omemo2WireB64(k.getAttribute('sig') ?? '');
      }
    }

    final spkEl = kids(el, 'spk').single;
    final kemSpkEl = kids(el, 'kem-spk').single;
    final pqIkEl = kids(el, 'pq-ik').single;
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
      spk: omemo2WireB64(spkEl.innerText),
      spkId: int.parse(spkEl.getAttribute('id')!),
      spkSignature: one('spks'),
      ik: one('ik'),
      prekeys: keyMap('prekeys', 'pk'),
      kemSpkId: int.parse(kemSpkEl.getAttribute('id')!),
      kemSpk: omemo2WireB64(kemSpkEl.innerText),
      kemSpkSignature: one('kem-spks'),
      kemPrekeys: kemPks,
      kemPrekeySignatures: kemSigs,
      pqIk: omemo2WireB64(pqIkEl.innerText),
      pqSig: one('pq-sig'),
      // Absent/empty → hasPqIdentity false (monocles never-downgrade).
      ikSig: () {
        final els = kids(el, 'ik-sig');
        return els.isEmpty ? '' : omemo2WireB64(els.first.innerText);
      }(),
    );
  }

  /// Raw 32-byte identity public key bytes.
  Uint8List get ikBytes => base64Decode(ik);

  /// Classical IdentityKey.serialize() form (0x05 ‖ 32).
  ///
  /// Wire `<ik>` is normally 32 bytes (monocles). Some peers may publish the
  /// already-tagged 33-byte form — do not double-prefix.
  Uint8List get ikSerialized {
    final raw = ikBytes;
    if (raw.length == 33 && raw.isNotEmpty && raw.first == 0x05) {
      return Uint8List.fromList(raw);
    }
    if (raw.length == 32) return Uint8List.fromList([0x05, ...raw]);
    if (raw.isNotEmpty && raw.first != 0x05) {
      return Uint8List.fromList([0x05, ...raw]);
    }
    return Uint8List.fromList(raw);
  }
}

/// monocles `IqParser.base64decode`: strip every whitespace run before decode.
///
/// PEP servers and XML pretty-printers wrap the ~6 KB `<pq-sig>` (and KEM
/// keys). Dart's [base64Decode] rejects those newlines, which used to look
/// like a missing `ik-sig` on an otherwise valid monocles bundle.
String omemo2WireB64(String raw) => raw.replaceAll(RegExp(r'\s+'), '');

/// @Deprecated Use [Omemo2Bundle].
typedef PqBundle = Omemo2Bundle;
