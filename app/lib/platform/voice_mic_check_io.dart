// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Best-effort "will this capture be silent?" before hold-to-talk.
// Supported: Linux (pactl mute **or** 0% volume), Android (AudioManager mute).
// Others (iOS / macOS / Windows / web): return null — skip the check.

import 'dart:io';

import 'package:flutter/services.dart';

const _audioChannel = MethodChannel('org.resonchat.resonchat/audio');

/// `true` when capture is effectively off, `false` when usable, `null` unknown.
///
/// On Linux, GNOME/KDE "turn off mic" often sets volume to 0% without Mute=yes
/// — both must be treated as blocked.
Future<bool?> isDefaultMicMuted() async {
  if (Platform.isLinux) return _linuxInputDisabled();
  if (Platform.isAndroid) return _androidMicrophoneMute();
  return null;
}

Future<bool?> _linuxInputDisabled() async {
  final muted = await _linuxSourceMuted();
  if (muted == true) return true;
  final silentVol = await _linuxSourceVolumeSilent();
  if (silentVol == true) return true;
  // Known unmuted with non-zero volume.
  if (muted == false && silentVol == false) return false;
  // Unmuted but volume unknown → allow; muted unknown + volume ok → allow.
  if (muted == false || silentVol == false) return false;
  return null;
}

Future<bool?> _linuxSourceMuted() async {
  try {
    final r = await Process.run('pactl', [
      'get-source-mute',
      '@DEFAULT_SOURCE@',
    ]);
    if (r.exitCode != 0) return null;
    return parsePactlMuteStdout(r.stdout as String);
  } catch (_) {}
  return null;
}

/// `true` when every reported channel is 0%.
Future<bool?> _linuxSourceVolumeSilent() async {
  try {
    final r = await Process.run('pactl', [
      'get-source-volume',
      '@DEFAULT_SOURCE@',
    ]);
    if (r.exitCode != 0) return null;
    return parsePactlVolumeSilentStdout(r.stdout as String);
  } catch (_) {}
  return null;
}

/// Parses `pactl get-source-mute` stdout (`Mute: yes` / `Mute: no`).
bool? parsePactlMuteStdout(String stdout) {
  final out = stdout.toLowerCase();
  if (out.contains('yes')) return true;
  if (out.contains('no')) return false;
  return null;
}

/// Parses `pactl get-source-volume` stdout; `true` when every `%` is 0.
///
/// Example: `front-left: 0 /   0% / -inf dB,   front-right: 0 /   0% / -inf dB`
bool? parsePactlVolumeSilentStdout(String stdout) {
  final percents = RegExp(r'(\d+)\s*%')
      .allMatches(stdout)
      .map((m) => int.parse(m.group(1)!))
      .toList();
  if (percents.isEmpty) return null;
  return percents.every((p) => p == 0);
}

Future<bool?> _androidMicrophoneMute() async {
  try {
    return await _audioChannel.invokeMethod<bool>('isMicrophoneMute');
  } catch (_) {
    return null;
  }
}
