// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Host CLI probes for Linux. Linked .so are bundled; these binaries are not.

import 'dart:convert';
import 'dart:io';

import 'package:resonchat/platform/linux_cli_types.dart';

const _parecordShimMarker = 'resonchat-parecord-shim';

/// Absolute path to [name] on PATH / common dirs, or `null`.
Future<String?> linuxCliPath(String name) async {
  if (!Platform.isLinux) return null;
  if (name.isEmpty || name.contains('/')) return null;

  final seen = <String>{};
  final dirs = <String>[
    ...?(Platform.environment['PATH']?.split(':')),
    '/usr/bin',
    '/bin',
    '/usr/local/bin',
  ];
  for (final dir in dirs) {
    if (dir.isEmpty || !seen.add(dir)) continue;
    final path = '$dir/$name';
    if (await File(path).exists()) return path;
  }
  return null;
}

Future<bool> linuxCliExists(String name) async =>
    (await linuxCliPath(name)) != null;

Future<bool> _isParecordShim(String path) async {
  try {
    final file = File(path);
    final len = await file.length();
    final n = len < 120 ? len : 120;
    final head = await file.openRead(0, n).transform(utf8.decoder).join();
    return head.contains(_parecordShimMarker);
  } catch (_) {
    return false;
  }
}

Future<bool> _realParecordOnPath() async {
  final seen = <String>{};
  final dirs = <String>[
    ...?(Platform.environment['PATH']?.split(':')),
    '/usr/bin',
    '/bin',
    '/usr/local/bin',
  ];
  for (final dir in dirs) {
    if (dir.isEmpty || !seen.add(dir)) continue;
    final path = '$dir/parecord';
    if (!await File(path).exists()) continue;
    if (!await _isParecordShim(path)) return true;
  }
  return false;
}

/// Stock [record_linux] always starts `parecord`. Packaged builds prepend a
/// shim that prefers `pw-record`. Capture is available when that chain works.
Future<bool> linuxVoiceCaptureAvailable() async {
  if (!Platform.isLinux) return false;
  // Shim + PipeWire, or any real Pulse parecord (shim may PATH-forward to it).
  if (await linuxCliExists('pw-record') && await linuxCliExists('parecord')) {
    return true;
  }
  return _realParecordOnPath();
}

/// Voice capture needs a PipeWire or Pulse recorder plus ffmpeg.
Future<void> ensureLinuxVoiceCaptureCli() async {
  if (!Platform.isLinux) return;
  if (!await linuxVoiceCaptureAvailable()) {
    throw MissingLinuxCli(const ['pw-record', 'parecord']);
  }
  if (!await linuxCliExists('ffmpeg')) {
    throw MissingLinuxCli(const ['ffmpeg']);
  }
}

Future<void> ensureLinuxXdgOpen() async {
  if (!Platform.isLinux) return;
  if (!await linuxCliExists('xdg-open')) {
    throw MissingLinuxCli(const ['xdg-open']);
  }
}
