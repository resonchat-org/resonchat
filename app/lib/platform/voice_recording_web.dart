// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Web: `record` returns a blob: URL from stop(); fetch bytes then revoke.

import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

/// Empty path — MediaRecorder writes to an in-memory blob.
Future<String> prepareRecordingPath(String extension) async => '';

Future<Uint8List?> takeRecordingBytes(String path) async {
  if (path.isEmpty) return null;
  try {
    final resp = await http.get(Uri.parse(path));
    _revoke(path);
    if (resp.statusCode < 200 || resp.statusCode >= 300) return null;
    return resp.bodyBytes.isEmpty ? null : resp.bodyBytes;
  } catch (_) {
    _revoke(path);
    return null;
  }
}

Future<void> discardRecordingPath(String path) async {
  _revoke(path);
}

void _revoke(String path) {
  if (!path.startsWith('blob:')) return;
  try {
    web.URL.revokeObjectURL(path);
  } catch (_) {}
}
