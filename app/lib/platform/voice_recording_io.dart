// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

Future<String> prepareRecordingPath(String extension) async {
  final dir = await getTemporaryDirectory();
  return p.join(
    dir.path,
    'voice_${DateTime.now().millisecondsSinceEpoch}.$extension',
  );
}

Future<Uint8List?> takeRecordingBytes(String path) async {
  final file = File(path);
  if (!await file.exists()) return null;
  final bytes = await file.readAsBytes();
  try {
    await file.delete();
  } catch (_) {}
  return bytes.isEmpty ? null : bytes;
}

Future<void> discardRecordingPath(String path) async {
  try {
    final file = File(path);
    if (await file.exists()) await file.delete();
  } catch (_) {}
}
