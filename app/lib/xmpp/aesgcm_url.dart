// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Conversations-compatible aesgcm:// URLs for HTTP File Upload (XEP-0363)
// with on-the-wire AES-256-GCM (see Conversations AesGcmURL / TransportSecurity).

import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:hex/hex.dart';

/// Matches Conversations `AesGcmURL.IV_KEY` (44- or 48-byte IV+key hex).
final _ivKeyHex = RegExp(r'^([A-Fa-f0-9]{2}){44}$|^([A-Fa-f0-9]{2}){48}$');

/// Conversations aesgcm URL helpers.
class AesGcmUrl {
  AesGcmUrl._();

  static const protocol = 'aesgcm';

  /// True when [url] is an aesgcm://…#iv+key link.
  static bool isAesGcm(String url) {
    if (!url.toLowerCase().startsWith('$protocol://')) return false;
    final hash = Uri.tryParse(url)?.fragment;
    return hash != null && _ivKeyHex.hasMatch(hash);
  }

  /// True when [text] looks like a downloadable HTTP(S) or aesgcm URL.
  static bool looksLikeFileUrl(String text) {
    final t = text.trim();
    if (t.contains('\n')) {
      // Conversations: first line is often the URL.
      return looksLikeFileUrl(t.split('\n').first);
    }
    final lower = t.toLowerCase();
    if (lower.startsWith('$protocol://')) return isAesGcm(t);
    if (lower.startsWith('https://') || lower.startsWith('http://')) {
      return Uri.tryParse(t)?.host.isNotEmpty ?? false;
    }
    return false;
  }

  /// First line if multi-line (Conversations download body split).
  static String primaryUrl(String body) {
    final line = body.trim().split('\n').first.trim();
    return line;
  }

  /// `https://…` download URL (fragment stripped). aesgcm → https.
  static Uri httpsUri(String url) {
    final raw = primaryUrl(url);
    final asHttps = raw.toLowerCase().startsWith('$protocol://')
        ? 'https${raw.substring(protocol.length)}'
        : raw;
    final parsed = Uri.parse(asHttps);
    return Uri(
      scheme: parsed.scheme,
      userInfo: parsed.userInfo,
      host: parsed.host,
      port: parsed.hasPort ? parsed.port : null,
      path: parsed.path,
      query: parsed.hasQuery ? parsed.query : null,
    );
  }

  /// Build aesgcm://host/path#iv||key from an https get URL and key material.
  ///
  /// Matches Conversations `AesGcmURL.toAesGcmUrl` + fragment from
  /// `TransportSecurity.asBytes()`.
  static String toAesGcmUrl(String httpsGetUrl, Uint8List ivAndKey) {
    final base = Uri.parse(httpsGetUrl).replace(fragment: '');
    if (base.scheme != 'https') {
      throw ArgumentError('aesgcm URLs require https get slots');
    }
    final withFrag = base.replace(fragment: HEX.encode(ivAndKey));
    return '$protocol${withFrag.toString().substring('https'.length)}';
  }

  /// Parse IV (12) + key (32) from a 44-byte fragment, or IV(16)+key(32) for 48.
  static ({Uint8List iv, Uint8List key}) parseAnchor(String fragment) {
    final bytes = Uint8List.fromList(HEX.decode(fragment));
    if (bytes.length == 44) {
      return (
        iv: Uint8List.sublistView(bytes, 0, 12),
        key: Uint8List.sublistView(bytes, 12, 44),
      );
    }
    if (bytes.length == 48) {
      return (
        iv: Uint8List.sublistView(bytes, 0, 16),
        key: Uint8List.sublistView(bytes, 16, 48),
      );
    }
    throw FormatException('Unrecognized aesgcm key+iv length ${bytes.length}');
  }

  /// Fresh 12-byte IV + 32-byte key (Conversations `ofKeyAndIv`).
  static Uint8List newKeyAndIv() {
    final rnd = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(44, (_) => rnd.nextInt(256)),
    );
  }
}

/// AES-256-GCM file crypto matching Conversations HTTP upload.
class AesGcmFileCrypto {
  AesGcmFileCrypto._();

  static final _algo = AesGcm.with256bits();

  /// Encrypt [clear]; returns ciphertext ‖ 16-byte tag (upload body size = n+16).
  static Future<Uint8List> encrypt(
    Uint8List clear,
    Uint8List ivAndKey,
  ) async {
    final parts = AesGcmUrl.parseAnchor(HEX.encode(ivAndKey));
    final secretKey = await _algo.newSecretKeyFromBytes(parts.key);
    final box = await _algo.encrypt(
      clear,
      secretKey: secretKey,
      nonce: parts.iv,
    );
    return Uint8List.fromList([...box.cipherText, ...box.mac.bytes]);
  }

  /// Decrypt upload body (ciphertext ‖ tag) using the URL fragment material.
  static Future<Uint8List> decrypt(
    Uint8List cipherAndTag,
    String fragment,
  ) async {
    if (cipherAndTag.length < 16) {
      throw FormatException('ciphertext too short');
    }
    final parts = AesGcmUrl.parseAnchor(fragment);
    final secretKey = await _algo.newSecretKeyFromBytes(parts.key);
    final cut = cipherAndTag.length - 16;
    final box = SecretBox(
      cipherAndTag.sublist(0, cut),
      nonce: parts.iv,
      mac: Mac(cipherAndTag.sublist(cut)),
    );
    final clear = await _algo.decrypt(box, secretKey: secretKey);
    return Uint8List.fromList(clear);
  }
}
