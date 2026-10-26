// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The file side of developer log mode: append lines to
// `resonchat-<stamp>.log` in one directory, roll over at a size, and keep only
// the newest few.
//
// Split out of [DevLog] (`dev_log_io.dart`) so this part — which is where a
// long-running install silently eats the device — can be tested against a temp
// directory without a platform channel for "where is the app support
// directory".

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Appends log lines to dated files inside [dir].
class LogFileWriter {
  LogFileWriter({
    required this.dir,
    this.maxBytes = 4 * 1024 * 1024,
    this.maxFiles = 5,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// Where the `resonchat-*.log` files live. Created on [open].
  final Directory dir;

  /// A file is closed and the next line starts a new one once it passes this.
  final int maxBytes;

  /// How many files are kept in [dir]. The oldest are deleted as new ones open.
  final int maxFiles;

  final DateTime Function() _clock;

  IOSink? _sink;
  File? _file;
  int _size = 0;

  /// The file lines are going to, or null when closed.
  File? get file => _file;

  static final _name = RegExp(r'^resonchat-(\d{8}-\d{6})(?:-(\d+))?\.log$');

  /// Every log file in [dir], oldest first.
  ///
  /// Sorting by stamp (and then by the suffix that disambiguates two files
  /// created inside the same second) rather than by raw name: `…-1.log` would
  /// sort *before* `….log`, since `-` is below `.`, putting the newest file
  /// first.
  Future<List<File>> files() async {
    if (!await dir.exists()) return const [];
    final found = <File>[];
    await for (final entry in dir.list()) {
      if (entry is! File) continue;
      if (_name.hasMatch(p.basename(entry.path))) found.add(entry);
    }
    found.sort((a, b) {
      final ka = _key(p.basename(a.path));
      final kb = _key(p.basename(b.path));
      final byStamp = ka.$1.compareTo(kb.$1);
      return byStamp != 0 ? byStamp : ka.$2.compareTo(kb.$2);
    });
    return found;
  }

  static (String, int) _key(String name) {
    final match = _name.firstMatch(name)!;
    return (match[1]!, int.tryParse(match[2] ?? '') ?? 0);
  }

  /// Opens the newest file, or a new one if it is missing or already full.
  Future<void> open() async {
    if (!await dir.exists()) await dir.create(recursive: true);
    final existing = await files();
    var target = existing.isEmpty ? null : existing.last;
    if (target != null && await target.length() >= maxBytes) target = null;
    // Appending to the newest rather than always starting a file keeps one
    // session's worth of history together across restarts.
    target ??= await _freshFile();
    _file = target;
    // A fresh name has no file behind it yet; `openWrite` creates it.
    _size = await target.exists() ? await target.length() : 0;
    _sink = target.openWrite(mode: FileMode.append);
    // Pruning *after* opening, not before: deleting first can free a name that
    // the file about to be created then takes, and the newest file would sort
    // as the oldest for the rest of its life.
    await prune();
  }

  /// A name nothing has taken yet. The suffix matters when a file rolls over
  /// within the same second as the one it is replacing — the stamp alone would
  /// name the new file after the full one it was meant to replace.
  Future<File> _freshFile() async {
    final stamp = _stamp(_clock());
    var candidate = File(p.join(dir.path, 'resonchat-$stamp.log'));
    var suffix = 1;
    while (await candidate.exists()) {
      candidate = File(p.join(dir.path, 'resonchat-$stamp-$suffix.log'));
      suffix++;
    }
    return candidate;
  }

  /// Appends [line]. Opens on first use; rolls over when [maxBytes] is passed.
  Future<void> write(String line) async {
    if (_sink == null) await open();
    final bytes = utf8.encode('$line\n');
    _sink!.add(bytes);
    _size += bytes.length;
    if (_size >= maxBytes) {
      await close();
      await open();
    }
  }

  /// Pushes buffered bytes to the filesystem. The sink buffers, and a crash
  /// loses whatever has not landed — hence the periodic flush in [DevLog].
  Future<void> flush() async {
    try {
      await _sink?.flush();
    } catch (_) {
      // A closed or revoked directory is not worth failing a log line over.
    }
  }

  /// Flushes and releases the file. Safe to call when already closed.
  Future<void> close() async {
    final sink = _sink;
    _sink = null;
    _file = null;
    _size = 0;
    if (sink == null) return;
    try {
      await sink.flush();
    } catch (_) {}
    try {
      await sink.close();
    } catch (_) {}
  }

  /// Deletes the oldest files until only [maxFiles] are left.
  Future<void> prune() async {
    final existing = await files();
    var excess = existing.length - maxFiles;
    var i = 0;
    while (excess > 0 && i < existing.length) {
      try {
        await existing[i].delete();
      } catch (_) {}
      excess--;
      i++;
    }
  }
}

/// `yyyyMMdd-HHmmss` in local time. Not `intl`: the log module stays free of
/// locale machinery, and this is a filename, not something anyone reads as a
/// date.
String _stamp(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year.toString().padLeft(4, '0')}${two(t.month)}${two(t.day)}'
      '-${two(t.hour)}${two(t.minute)}${two(t.second)}';
}
