// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Developer log mode: tee every `package:logging` record into a file in the
// app's private support directory, and copy the newest one into the user's
// Downloads folder on request.
//
// Why private first and export second. On Android 10+ the public Downloads
// collection is reachable only through MediaStore, which is built around
// writing a file once and then finalising it; appending to a MediaStore entry
// across an app run is not a supported operation, and the tail of a log lost
// to a crash is exactly the part worth having. A private directory takes
// ordinary appends, and the export is one whole-file copy at a moment the user
// chose. Desktop copies straight into its own Downloads directory; the web
// stub has neither and does nothing.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'dev_log_prefs.dart';
import 'log_file_writer.dart';
import 'log_line.dart';

/// Owns the log file and the [Logger.root] subscription for a native build.
class DevLog {
  DevLog({this.logDir});

  /// Test/override seam for the log directory. Default: `<support>/logs`.
  final Directory Function()? logDir;

  /// Android side of the export (see `MainActivity`'s `logs` channel).
  static const _channel = MethodChannel('org.resonchat.resonchat/logs');

  LogFileWriter? _writer;
  StreamSubscription<LogRecord>? _sub;
  Timer? _flushTimer;
  Future<void>? _busy;

  /// Files under the support directory, never the shared storage.
  static const dirName = 'logs';

  /// Whether this build can hold a log file at all.
  bool get supported => true;

  /// True while records are being written.
  bool get running => _sub != null;

  /// The file being written, or null when off.
  File? get file => _writer?.file;

  Future<Directory> _dir() async {
    final override = logDir;
    if (override != null) return override();
    final support = await getApplicationSupportDirectory();
    return Directory(p.join(support.path, dirName));
  }

  /// Starts writing. Idempotent, and safe to call at boot as well as on the
  /// settings toggle.
  Future<void> start() {
    final inFlight = _busy;
    if (inFlight != null) return inFlight;
    return _busy = _start().whenComplete(() => _busy = null);
  }

  Future<void> _start() async {
    if (running) return;
    final writer = LogFileWriter(dir: await _dir());
    await writer.open();
    _writer = writer;

    // Default root level is INFO, and the interesting lines — which device
    // list a peer published, why a bundle was refused — are logged at FINE by
    // the track managers. Asking for the file is asking for those.
    Logger.root.level = Level.ALL;

    // Records are delivered in order, but `write` can await (it opens on the
    // first call and rolls over when full), so chain them explicitly rather
    // than letting two awaits interleave and shuffle the file.
    var chain = Future<void>.value();
    _sub = Logger.root.onRecord.listen((record) {
      final line = formatLogRecord(record, redact: true);
      chain = chain.then((_) async {
        try {
          await _writer?.write(line);
        } catch (_) {
          // Losing a line must not take the app down with it.
        }
      });
    });

    // The sink buffers; without this a crash costs the last few seconds, which
    // is when the interesting thing happened.
    _flushTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => unawaited(_writer?.flush() ?? Future<void>.value()),
    );
  }

  /// Stops writing and closes the file.
  Future<void> stop() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    final sub = _sub;
    _sub = null;
    await sub?.cancel();
    final writer = _writer;
    _writer = null;
    await writer?.close();
    // Debug builds keep everything on the console; a release build goes back
    // to the level the app ships with.
    if (!kDebugMode) Logger.root.level = Level.INFO;
  }

  /// Applies the setting: persists it, then starts or stops.
  Future<void> setEnabled(bool enabled) async {
    await saveDevLogEnabled(enabled);
    if (enabled) {
      await start();
    } else {
      await stop();
    }
  }

  /// Copies the newest log file into the user's Downloads folder.
  ///
  /// Returns where it landed, or null when there is nothing to copy or the
  /// platform has no public Downloads to copy into.
  Future<String?> exportToDownloads() async {
    await _writer?.flush();
    final newest = await _newestFile();
    if (newest == null) return null;
    final name = p.basename(newest.path);

    if (Platform.isAndroid) {
      // MediaStore, because the manifest deliberately requests no storage
      // permission (see AndroidManifest's tools:node="remove" block).
      return _channel.invokeMethod<String>('saveToDownloads', {
        'name': name,
        'bytes': await newest.readAsBytes(),
      });
    }
    final downloads = await getDownloadsDirectory();
    if (downloads == null) return null;
    final target = File(p.join(downloads.path, name));
    await newest.copy(target.path);
    return target.path;
  }

  Future<File?> _newestFile() async {
    final all = await LogFileWriter(dir: await _dir()).files();
    return all.isEmpty ? null : all.last;
  }
}

/// The running instance. One per process: log mode is app-wide.
final devLog = DevLog();
