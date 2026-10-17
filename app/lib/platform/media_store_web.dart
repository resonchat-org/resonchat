// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// In-memory media cache for web (session-scoped). Paths are opaque keys
// stored in [Message.localPath].

import 'dart:typed_data';

/// Memory-backed media cache for the browser.
class MediaStore {
  final Map<String, Uint8List> _bytes = {};

  Future<String> writeBytes(Uint8List bytes, String preferredName) async {
    final key =
        'mem://${DateTime.now().microsecondsSinceEpoch}_${_safeName(preferredName)}';
    _bytes[key] = bytes;
    return key;
  }

  Future<String> copyLocal(String sourcePath, {String? preferredName}) async {
    final existing = _bytes[sourcePath];
    if (existing == null) {
      throw StateError('unknown media path: $sourcePath');
    }
    return writeBytes(existing, preferredName ?? 'file');
  }

  Future<Uint8List?> readBytes(String path) async => _bytes[path];

  bool existsSync(String path) => path.isNotEmpty && _bytes.containsKey(path);

  Future<void> deletePath(String path) async {
    _bytes.remove(path);
  }

  Future<void> deletePaths(Iterable<String> paths) async {
    for (final path in paths) {
      await deletePath(path);
    }
  }

  /// Web has no public Downloads; returns the same memory key after a copy.
  Future<String> copyToPublic(
    String sourcePath, {
    String? mime,
    String? preferredName,
  }) async {
    final existing = _bytes[sourcePath];
    if (existing == null) {
      throw StateError('unknown media path: $sourcePath');
    }
    return writeBytes(existing, preferredName ?? 'file');
  }

  String _safeName(String name) {
    final base = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return base.isEmpty ? 'file' : base;
  }
}

final mediaStore = MediaStore();
