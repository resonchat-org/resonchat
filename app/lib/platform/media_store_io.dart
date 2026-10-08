// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Disk-backed media cache for native platforms.
class MediaStore {
  Future<String> writeBytes(Uint8List bytes, String preferredName) async {
    final dir = await _mediaDir();
    final safe = _safeName(preferredName);
    final out = File(
      p.join(dir.path, '${DateTime.now().microsecondsSinceEpoch}_$safe'),
    );
    await out.writeAsBytes(bytes, flush: true);
    return out.path;
  }

  Future<String> copyLocal(String sourcePath, {String? preferredName}) async {
    final dir = await _mediaDir();
    final safe = _safeName(preferredName ?? p.basename(sourcePath));
    final out = File(
      p.join(dir.path, '${DateTime.now().microsecondsSinceEpoch}_$safe'),
    );
    await File(sourcePath).copy(out.path);
    return out.path;
  }

  Future<Uint8List?> readBytes(String path) async {
    final f = File(path);
    if (!await f.exists()) return null;
    return f.readAsBytes();
  }

  bool existsSync(String path) => path.isNotEmpty && File(path).existsSync();

  Future<Directory> _mediaDir() async {
    final root = await getApplicationSupportDirectory();
    final dir = Directory(p.join(root.path, 'media'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  String _safeName(String name) {
    final base = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return base.isEmpty ? 'file' : base;
  }
}

final mediaStore = MediaStore();
