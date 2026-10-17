// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Best-effort "will this capture be silent?" before hold-to-talk.
// Linux: wpctl, else pactl. Android / Windows: MethodChannel. Others: skip.

import 'dart:io';

import 'package:flutter/services.dart';

import 'linux_cli_io.dart';
import 'linux_cli_types.dart';

const _audioChannel = MethodChannel('org.resonchat.resonchat/audio');

/// Soft-mute probe. Never throws.
Future<MicMuteProbe> probeDefaultMicMute() async {
  if (Platform.isLinux) return _linuxProbe();
  // Android: AudioManager.isMicrophoneMute.
  // Windows: WASAPI default capture mute / 0% volume (runner/audio_mute.cpp).
  if (Platform.isAndroid || Platform.isWindows) {
    final muted = await _channelMicrophoneMute();
    return MicMuteProbe(muted: muted);
  }
  return const MicMuteProbe();
}

/// Convenience: mute flag only (`null` = skip / unknown).
Future<bool?> isDefaultMicMuted() async => (await probeDefaultMicMute()).muted;

Future<MicMuteProbe> _linuxProbe() async {
  final hasWpctl = await linuxCliExists('wpctl');
  final hasPactl = await linuxCliExists('pactl');

  if (hasWpctl) {
    final muted = await _linuxWpctlInputDisabled();
    if (muted != null) return MicMuteProbe(muted: muted);
  }
  if (hasPactl) {
    final muted = await _linuxPactlInputDisabled();
    if (muted != null) return MicMuteProbe(muted: muted);
  }

  final missing = <String>[if (!hasWpctl) 'wpctl', if (!hasPactl) 'pactl'];
  // Tools present but unreadable → unknown, no "missing" snackbar.
  return MicMuteProbe(missingCli: missing);
}

Future<bool?> _linuxWpctlInputDisabled() async {
  try {
    final r = await Process.run(
      'wpctl',
      ['get-volume', '@DEFAULT_AUDIO_SOURCE@'],
      environment: {'LC_ALL': 'C'},
    );
    if (r.exitCode != 0) return null;
    return parseWpctlVolumeStdout(r.stdout as String);
  } catch (_) {}
  return null;
}

Future<bool?> _linuxPactlInputDisabled() async {
  final muted = await _linuxPactlSourceMuted();
  if (muted == true) return true;
  final silentVol = await _linuxPactlSourceVolumeSilent();
  if (silentVol == true) return true;
  if (muted == false && silentVol == false) return false;
  if (muted == false || silentVol == false) return false;
  return null;
}

Future<bool?> _linuxPactlSourceMuted() async {
  try {
    final r = await Process.run(
      'pactl',
      ['get-source-mute', '@DEFAULT_SOURCE@'],
      environment: {'LC_ALL': 'C'},
    );
    if (r.exitCode != 0) return null;
    return parsePactlMuteStdout(r.stdout as String);
  } catch (_) {}
  return null;
}

Future<bool?> _linuxPactlSourceVolumeSilent() async {
  try {
    final r = await Process.run(
      'pactl',
      ['get-source-volume', '@DEFAULT_SOURCE@'],
      environment: {'LC_ALL': 'C'},
    );
    if (r.exitCode != 0) return null;
    return parsePactlVolumeSilentStdout(r.stdout as String);
  } catch (_) {}
  return null;
}

/// Parses `wpctl get-volume` (`Volume: 1.00`, `Volume: 0.50 [MUTED]`).
bool? parseWpctlVolumeStdout(String stdout) {
  final match = RegExp(
    r'Volume:\s*([0-9]*\.?[0-9]+)\s*(\[MUTED\])?',
    caseSensitive: false,
  ).firstMatch(stdout);
  if (match == null) return null;
  final volume = double.tryParse(match.group(1)!);
  if (volume == null) return null;
  if (match.group(2) != null) return true;
  return volume <= 0.0;
}

bool? parsePactlMuteStdout(String stdout) {
  final out = stdout.toLowerCase();
  if (out.contains('yes')) return true;
  if (out.contains('no')) return false;
  return null;
}

bool? parsePactlVolumeSilentStdout(String stdout) {
  final percents = RegExp(r'(\d+)\s*%')
      .allMatches(stdout)
      .map((m) => int.parse(m.group(1)!))
      .toList();
  if (percents.isEmpty) return null;
  return percents.every((p) => p == 0);
}

Future<bool?> _channelMicrophoneMute() async {
  try {
    return await _audioChannel.invokeMethod<bool>('isMicrophoneMute');
  } catch (_) {
    return null;
  }
}
