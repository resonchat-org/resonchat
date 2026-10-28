// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Conversations / monocles `Account.getShareableUri` / `XmppUri`:
// `xmpp:` + light-escaped bare JID + fingerprint query params joined by `;`.
//
// Legacy OMEMO (A-track): `omemo-sid-<id>=` classical IK hex without `05`.
// PQ OMEMO2 (B-track, proto-XEP §10.1): `omemo-pq-sid-<id>=` classical IK
// without `05`, plus `omemo-pq-hfp-<id>=` hybrid SHA3-512 hex (128 chars).

import 'dart:convert';

import 'package:resonchat/crypto/fingerprint.dart';

/// Share URI encoded the way monocles builds `XmppUri.getFingerprintUri`.
///
/// [deviceId] with [legacyFingerprint] → `omemo-sid-*` (A-track).
/// [deviceId] with [omemo2ClassicalFingerprint] → `omemo-pq-sid-*`; when
/// [hybridFingerprint] is also set, appends `omemo-pq-hfp-*`.
/// [verifiedOwnDevices] / [verifiedOwnPqDevices] are other own sessions
/// monocles adds only when trust is verified and active.
String accountShareUri({
  required String bareJid,
  int? deviceId,
  String? legacyFingerprint,
  String? omemo2ClassicalFingerprint,
  String? hybridFingerprint,
  List<({int deviceId, String fingerprint})> verifiedOwnDevices = const [],
  List<({int deviceId, String classical, String? hybrid})>
      verifiedOwnPqDevices =
      const [],
}) {
  final params = <String>[];
  void addSid(String prefix, int id, String fingerprint) {
    final value = formatFingerprint(fingerprint, spaces: false);
    if (value.isEmpty) return;
    params.add('${_urlEncode('$prefix$id')}=${_urlEncode(value)}');
  }

  void addPq(int id, String classical, String? hybrid) {
    addSid('omemo-pq-sid-', id, classical);
    if (hybrid == null || hybrid.isEmpty) return;
    final h = formatFingerprint(hybrid, spaces: false);
    if (h.length != 128) return;
    params.add('${_urlEncode('omemo-pq-hfp-$id')}=${_urlEncode(h)}');
  }

  if (deviceId != null &&
      legacyFingerprint != null &&
      legacyFingerprint.isNotEmpty) {
    addSid('omemo-sid-', deviceId, legacyFingerprint);
  }
  for (final device in verifiedOwnDevices) {
    addSid('omemo-sid-', device.deviceId, device.fingerprint);
  }
  if (deviceId != null &&
      omemo2ClassicalFingerprint != null &&
      omemo2ClassicalFingerprint.isNotEmpty) {
    addPq(deviceId, omemo2ClassicalFingerprint, hybridFingerprint);
  }
  for (final device in verifiedOwnPqDevices) {
    addPq(device.deviceId, device.classical, device.hybrid);
  }

  final jid = _lightEscape(bareJid);
  if (params.isEmpty) return 'xmpp:$jid';
  return 'xmpp:$jid?${params.join(';')}';
}

/// Gajim / Conversations MUC join IRI: `xmpp:room@conf?join`.
String roomJoinUri(String bareJid) => 'xmpp:${_lightEscape(bareJid)}?join';

/// One `omemo-sid-<deviceId>=<fingerprint>` pair from an `xmpp:` URI.
typedef OmemoSidFingerprint = ({int deviceId, String fingerprint});

/// One PQ OMEMO2 URI pair: classical `omemo-pq-sid-` plus optional hybrid.
typedef OmemoPqUriFingerprint = ({
  int deviceId,
  String classical,
  String? hybrid,
});

final _omemoSidKey = RegExp(r'^omemo-sid-(\d+)$');
final _omemoPqSidKey = RegExp(r'^omemo-pq-sid-(\d+)$');
final _omemoPqHfpKey = RegExp(r'^omemo-pq-hfp-(\d+)$');
final _hexFingerprint = RegExp(r'^[0-9a-f]+$');

/// Conversations `XmppUri.parseFingerprints` for `omemo-sid-*` only.
///
/// Values are lowercase hex without spaces; classic keys are 64 chars (no
/// leading `05`). Invalid keys or lengths are skipped.
List<OmemoSidFingerprint> parseOmemoSidFingerprints(
  Map<String, String> params,
) {
  final out = <OmemoSidFingerprint>[];
  for (final entry in params.entries) {
    final match = _omemoSidKey.firstMatch(entry.key);
    if (match == null) continue;
    final id = int.tryParse(match.group(1)!);
    if (id == null || id <= 0) continue;
    var fp = entry.value.replaceAll(RegExp(r'\s+'), '').toLowerCase();
    // Reject the Conversations wire form that still has the type byte.
    if (fp.length == 66 && fp.startsWith('05')) continue;
    if (fp.length != 64 || !_hexFingerprint.hasMatch(fp)) continue;
    out.add((deviceId: id, fingerprint: fp));
  }
  return out;
}

/// Proto-XEP §10.1: `omemo-pq-sid-*` + optional matching `omemo-pq-hfp-*`.
List<OmemoPqUriFingerprint> parseOmemoPqFingerprints(
  Map<String, String> params,
) {
  final hybrids = <int, String>{};
  for (final entry in params.entries) {
    final match = _omemoPqHfpKey.firstMatch(entry.key);
    if (match == null) continue;
    final id = int.tryParse(match.group(1)!);
    if (id == null || id <= 0) continue;
    var h = entry.value.replaceAll(RegExp(r'\s+'), '').toLowerCase();
    if (h.length != 128 || !_hexFingerprint.hasMatch(h)) continue;
    hybrids[id] = h;
  }
  final out = <OmemoPqUriFingerprint>[];
  for (final entry in params.entries) {
    final match = _omemoPqSidKey.firstMatch(entry.key);
    if (match == null) continue;
    final id = int.tryParse(match.group(1)!);
    if (id == null || id <= 0) continue;
    var fp = entry.value.replaceAll(RegExp(r'\s+'), '').toLowerCase();
    if (fp.length == 66 && fp.startsWith('05')) fp = fp.substring(2);
    if (fp.length != 64 || !_hexFingerprint.hasMatch(fp)) continue;
    out.add((deviceId: id, classical: fp, hybrid: hybrids[id]));
  }
  return out;
}

/// Map a URI fingerprint onto the local store form (`axolotlFingerprint`:
/// 66 hex chars including the leading `05`).
String fingerprintForTrustStore(String uriFingerprint) {
  final n = uriFingerprint.replaceAll(RegExp(r'\s+'), '').toLowerCase();
  if (n.length == 64 && _hexFingerprint.hasMatch(n)) return '05$n';
  return n;
}

/// `MiniUri.LIGHT_URI_ESCAPER`: only `#` and `%`, as lowercase `%02x`.
String _lightEscape(String jid) {
  final out = StringBuffer();
  for (final unit in jid.codeUnits) {
    if (unit == 0x23 || unit == 0x25) {
      out.write('%${unit.toRadixString(16).padLeft(2, '0')}');
    } else {
      out.writeCharCode(unit);
    }
  }
  return out.toString();
}

/// Java `URLEncoder.encode(input, "UTF-8")`.
String _urlEncode(String input) {
  final out = StringBuffer();
  for (final byte in utf8.encode(input)) {
    final unreserved =
        (byte >= 0x41 && byte <= 0x5a) ||
        (byte >= 0x61 && byte <= 0x7a) ||
        (byte >= 0x30 && byte <= 0x39) ||
        byte == 0x2e ||
        byte == 0x2d ||
        byte == 0x2a ||
        byte == 0x5f;
    if (unreserved) {
      out.writeCharCode(byte);
    } else if (byte == 0x20) {
      out.write('+');
    } else {
      out.write('%${byte.toRadixString(16).padLeft(2, '0').toUpperCase()}');
    }
  }
  return out.toString();
}
