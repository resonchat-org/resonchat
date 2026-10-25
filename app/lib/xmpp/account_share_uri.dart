// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Conversations `Account.getShareableUri` / `MiniUri.Xmpp`:
// `xmpp:` + light-escaped bare JID + `?omemo-sid-<id>=<fingerprint>`
// joined by `;`. The fingerprint is [formatFingerprint] with spaces off
// (identity-key hex without the leading `05`).

import 'dart:convert';

import 'package:resonchat/crypto/fingerprint.dart';

/// Share URI encoded the way Conversations builds `MiniUri.Xmpp`.
///
/// [deviceId] and [legacyFingerprint] are this installation (always
/// included when both are present). [verifiedOwnDevices] are other own
/// sessions Conversations adds only when trust is verified and active,
/// in that same order.
String accountShareUri({
  required String bareJid,
  int? deviceId,
  String? legacyFingerprint,
  List<({int deviceId, String fingerprint})> verifiedOwnDevices = const [],
}) {
  final params = <String>[];
  void add(int id, String fingerprint) {
    final value = formatFingerprint(fingerprint, spaces: false);
    if (value.isEmpty) return;
    params.add('${_urlEncode('omemo-sid-$id')}=${_urlEncode(value)}');
  }

  if (deviceId != null &&
      legacyFingerprint != null &&
      legacyFingerprint.isNotEmpty) {
    add(deviceId, legacyFingerprint);
  }
  for (final device in verifiedOwnDevices) {
    add(device.deviceId, device.fingerprint);
  }
  final jid = _lightEscape(bareJid);
  if (params.isEmpty) return 'xmpp:$jid';
  return 'xmpp:$jid?${params.join(';')}';
}

/// Gajim / Conversations MUC join IRI: `xmpp:room@conf?join`.
String roomJoinUri(String bareJid) => 'xmpp:${_lightEscape(bareJid)}?join';

/// One `omemo-sid-<deviceId>=<fingerprint>` pair from an `xmpp:` URI.
typedef OmemoSidFingerprint = ({int deviceId, String fingerprint});

final _omemoSidKey = RegExp(r'^omemo-sid-(\d+)$');
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
