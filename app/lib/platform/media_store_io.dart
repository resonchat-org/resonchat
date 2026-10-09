// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Chat media lives under the app support directory (private), matching Copinc
// `getExternalFilesDir`. A permanent copy in Downloads / Pictures only happens
// when the user explicitly saves (long-press → Save).

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

  /// Removes a private cache file. Ignores missing paths and non-owned files.
  Future<void> deletePath(String path) async {
    if (path.isEmpty || path.startsWith('mem://')) return;
    try {
      final root = await _mediaDir();
      final normalized = p.normalize(path);
      // Only unlink files under our private media tree (never user Downloads).
      if (!p.isWithin(root.path, normalized)) return;
      final file = File(normalized);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  Future<void> deletePaths(Iterable<String> paths) async {
    for (final path in paths) {
      await deletePath(path);
    }
  }

  /// Copies [sourcePath] into a public Downloads/Pictures/Movies folder
  /// (Copinc `copyFileToPublic`). Returns the destination path.
  Future<String> copyToPublic(
    String sourcePath, {
    String? mime,
    String? preferredName,
  }) async {
    final src = File(sourcePath);
    if (!await src.exists()) {
      throw StateError('file not found: $sourcePath');
    }
    final dir = await _publicDir(mime);
    if (!await dir.exists()) await dir.create(recursive: true);
    final name = _uniquePublicName(
      dir,
      _safeName(preferredName ?? p.basename(sourcePath)),
    );
    final dest = File(p.join(dir.path, name));
    await src.copy(dest.path);
    return dest.path;
  }

  Future<Directory> _mediaDir() async {
    final root = await getApplicationSupportDirectory();
    final dir = Directory(p.join(root.path, 'media'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<Directory> _publicDir(String? mime) async {
    final downloads = await getDownloadsDirectory();
    final base =
        downloads ??
        Directory(
          p.join((await getApplicationDocumentsDirectory()).path, 'Downloads'),
        );
    final m = (mime ?? '').toLowerCase();
    if (m.startsWith('image/')) {
      return Directory(p.join(base.parent.path, 'Pictures'));
    }
    if (m.startsWith('video/')) {
      return Directory(p.join(base.parent.path, 'Movies'));
    }
    return base;
  }

  String _uniquePublicName(Directory dir, String preferred) {
    final candidate = File(p.join(dir.path, preferred));
    if (!candidate.existsSync()) return preferred;
    final stem = p.basenameWithoutExtension(preferred);
    final ext = p.extension(preferred);
    for (var i = 1; i < 1000; i++) {
      final name = '${stem}_$i$ext';
      if (!File(p.join(dir.path, name)).existsSync()) return name;
    }
    return '${DateTime.now().microsecondsSinceEpoch}_$preferred';
  }

  String _safeName(String name) {
    final base = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return base.isEmpty ? 'file' : base;
  }
}

final mediaStore = MediaStore();
