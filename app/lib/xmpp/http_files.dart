// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// App-layer HTTP I/O on top of moxxmpp's XEP-0363 manager.
//
// Slot discovery / request: [HttpFileUploadManager] (vendor/moxxmpp).
// OOB parse/send: [OOBManager] (XEP-0066).
// PUT/GET + Conversations aesgcm://: here (same split as Conversations
// HttpUploadManager vs HttpUploadConnection / HttpDownloadConnection).

import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:mime/mime.dart';
import 'package:moxxmpp/moxxmpp.dart';
import 'package:path/path.dart' as p;

import '../net/app_network.dart';
import '../platform/media_store.dart';
import 'aesgcm_url.dart';

final _log = Logger('HttpFiles');

/// Result of a successful upload ready to put in a message body / OOB.
class UploadedFile {
  const UploadedFile({
    required this.shareUrl,
    required this.mime,
    required this.fileName,
    required this.size,
    required this.encrypted,
  });

  /// https://… or aesgcm://…#iv+key for the peer.
  final String shareUrl;
  final String mime;
  final String fileName;
  final int size;
  final bool encrypted;
}

/// Opaque local media handle (native file path or web memory key).
class CachedMedia {
  const CachedMedia(this.path);
  final String path;
}

/// Automatic preview stopped because the body is larger than the cap.
class DownloadTooLarge implements Exception {
  DownloadTooLarge(this.bytes);
  final int bytes;

  @override
  String toString() => 'DownloadTooLarge($bytes)';
}

/// PUT/GET + aesgcm around moxxmpp [HttpFileUploadManager].
class HttpFileService {
  HttpFileService(this._connection);

  final XmppConnection? Function() _connection;

  HttpFileUploadManager? get _upload => _connection()
      ?.getManagerById<HttpFileUploadManager>(httpFileUploadManager);

  /// Delegates to [HttpFileUploadManager.isSupported].
  Future<bool> isAvailable() async {
    final m = _upload;
    if (m == null) return false;
    try {
      return await m.isSupported();
    } catch (e) {
      _log.warning('HTTP upload discovery failed: $e');
      return false;
    }
  }

  /// Slot via XEP-0363, then HTTP PUT. When [encrypt], Conversations aesgcm.
  Future<UploadedFile> uploadBytes(
    Uint8List clear, {
    required String fileName,
    required bool encrypt,
    String? mimeOverride,
  }) async {
    final m = _upload;
    if (m == null) throw StateError('HttpFileUploadManager not registered');

    final name = p.basename(fileName);
    final mime =
        mimeOverride ?? lookupMimeType(fileName) ?? 'application/octet-stream';

    late final Uint8List body;
    Uint8List? keyIv;
    if (encrypt) {
      keyIv = AesGcmUrl.newKeyAndIv();
      body = await AesGcmFileCrypto.encrypt(clear, keyIv);
    } else {
      body = clear;
    }

    final slotResult = await m.requestUploadSlot(
      name,
      body.length,
      contentType: mime,
    );
    if (!slotResult.isType<HttpFileUploadSlot>()) {
      throw StateError('upload slot failed: ${slotResult.dataRuntimeType}');
    }
    final slot = slotResult.get<HttpFileUploadSlot>();

    final client = appNetwork.createHttpClient();
    late final http.Response put;
    try {
      put = await client.put(
        Uri.parse(slot.putUrl),
        headers: {
          'Content-Type': mime,
          'Content-Length': '${body.length}',
          ...slot.headers,
        },
        body: body,
      );
    } finally {
      client.close();
    }
    if (put.statusCode != 200 && put.statusCode != 201) {
      throw http.ClientException(
        'upload PUT failed with ${put.statusCode}',
        Uri.parse(slot.putUrl),
      );
    }

    final share = keyIv == null
        ? slot.getUrl
        : AesGcmUrl.toAesGcmUrl(slot.getUrl, keyIv);
    _log.info('uploaded $name (${body.length} B, encrypt=$encrypt)');
    return UploadedFile(
      shareUrl: share,
      mime: mime,
      fileName: name,
      size: clear.length,
      encrypted: keyIv != null,
    );
  }

  /// Download [shareUrl] into the media store; decrypt when aesgcm.
  ///
  /// When [maxBytes] is set and positive, stop without writing a file if the
  /// declared or received length exceeds it ([DownloadTooLarge]).
  Future<CachedMedia> downloadToCache(
    String shareUrl, {
    String? preferredName,
    int? maxBytes,
  }) async {
    final https = AesGcmUrl.httpsUri(shareUrl);
    final client = appNetwork.createHttpClient();
    late Uint8List bytes;
    try {
      final resp = await client.send(http.Request('GET', https));
      if (resp.statusCode != 200 && resp.statusCode != 206) {
        await resp.stream.drain<void>();
        throw http.ClientException(
          'download failed with ${resp.statusCode}',
          https,
        );
      }
      final cap = maxBytes != null && maxBytes > 0 ? maxBytes : null;
      final declared = resp.contentLength;
      if (cap != null && declared != null && declared > cap) {
        await resp.stream.drain<void>();
        throw DownloadTooLarge(declared);
      }
      final builder = BytesBuilder(copy: false);
      var total = 0;
      await for (final chunk in resp.stream) {
        total += chunk.length;
        if (cap != null && total > cap) {
          throw DownloadTooLarge(total);
        }
        builder.add(chunk);
      }
      bytes = builder.takeBytes();
    } finally {
      client.close();
    }
    final frag = Uri.tryParse(AesGcmUrl.primaryUrl(shareUrl))?.fragment;
    if (frag != null && frag.isNotEmpty && AesGcmUrl.isAesGcm(shareUrl)) {
      bytes = await AesGcmFileCrypto.decrypt(bytes, frag);
    }

    final base =
        preferredName ??
        p.basename(https.path).replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final path = await mediaStore.writeBytes(
      Uint8List.fromList(bytes),
      base.isEmpty ? 'file' : base,
    );
    return CachedMedia(path);
  }

  /// Copy local bytes into the media cache (outgoing preview / reopen).
  Future<CachedMedia> cacheLocalBytes(
    Uint8List bytes, {
    String? preferredName,
  }) async {
    final path = await mediaStore.writeBytes(bytes, preferredName ?? 'file');
    return CachedMedia(path);
  }
}
