// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// App-layer HTTP I/O on top of moxxmpp's XEP-0363 manager.
//
// Slot discovery / request: [HttpFileUploadManager] (packages/moxxmpp).
// OOB parse/send: [OOBManager] (XEP-0066).
// PUT/GET + Conversations aesgcm://: here (same split as Conversations
// HttpUploadManager vs HttpUploadConnection / HttpDownloadConnection).

import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:mime/mime.dart';
import 'package:moxxmpp/moxxmpp.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

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

/// PUT/GET + aesgcm around moxxmpp [HttpFileUploadManager].
class HttpFileService {
  HttpFileService(this._connection);

  final XmppConnection? Function() _connection;

  HttpFileUploadManager? get _upload =>
      _connection()?.getManagerById<HttpFileUploadManager>(httpFileUploadManager);

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
  Future<UploadedFile> uploadFile(
    File file, {
    required bool encrypt,
    String? mimeOverride,
  }) async {
    final m = _upload;
    if (m == null) throw StateError('HttpFileUploadManager not registered');

    final name = p.basename(file.path);
    final mime = mimeOverride ??
        lookupMimeType(file.path) ??
        'application/octet-stream';
    final clear = await file.readAsBytes();

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

    final put = await http.put(
      Uri.parse(slot.putUrl),
      headers: {
        'Content-Type': mime,
        'Content-Length': '${body.length}',
        ...slot.headers,
      },
      body: body,
    );
    if (put.statusCode != 200 && put.statusCode != 201) {
      throw HttpException(
        'upload PUT failed with ${put.statusCode}',
        uri: Uri.parse(slot.putUrl),
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

  /// Download [shareUrl] into the app cache; decrypt when aesgcm.
  ///
  /// Returns the local file path.
  Future<File> downloadToCache(
    String shareUrl, {
    String? preferredName,
  }) async {
    final https = AesGcmUrl.httpsUri(shareUrl);
    final resp = await http.get(https);
    if (resp.statusCode != 200 && resp.statusCode != 206) {
      throw HttpException(
        'download failed with ${resp.statusCode}',
        uri: https,
      );
    }
    var bytes = resp.bodyBytes;
    final frag = Uri.tryParse(AesGcmUrl.primaryUrl(shareUrl))?.fragment;
    if (frag != null && frag.isNotEmpty && AesGcmUrl.isAesGcm(shareUrl)) {
      bytes = await AesGcmFileCrypto.decrypt(Uint8List.fromList(bytes), frag);
    }

    final dir = await _mediaDir();
    final base = preferredName ??
        p.basename(https.path).replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final safe = base.isEmpty ? 'file' : base;
    final out = File(
      p.join(
        dir.path,
        '${DateTime.now().microsecondsSinceEpoch}_$safe',
      ),
    );
    await out.writeAsBytes(bytes, flush: true);
    return out;
  }

  /// Copy a local [source] into the media cache (outgoing preview / reopen).
  Future<File> cacheLocalCopy(File source, {String? preferredName}) async {
    final dir = await _mediaDir();
    final base = preferredName ??
        p.basename(source.path).replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final safe = base.isEmpty ? 'file' : base;
    final out = File(
      p.join(
        dir.path,
        '${DateTime.now().microsecondsSinceEpoch}_$safe',
      ),
    );
    await source.copy(out.path);
    return out;
  }

  Future<Directory> _mediaDir() async {
    final root = await getApplicationSupportDirectory();
    final dir = Directory(p.join(root.path, 'media'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }
}
