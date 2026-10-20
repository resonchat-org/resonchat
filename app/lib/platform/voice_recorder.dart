// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Hold-to-talk mic capture (Telegram ChatActivityEnterView / MediaController).
// Native: AAC (.m4a). Web: Opus/WebM when available, else WAV.

import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;

import 'package:record/record.dart';

import 'package:resonchat/platform/linux_cli_io.dart'
    if (dart.library.js_interop) 'package:resonchat/platform/linux_cli_stub.dart';
import 'package:resonchat/platform/linux_cli_types.dart';
import 'package:resonchat/platform/voice_mic_check_io.dart'
    if (dart.library.js_interop) 'package:resonchat/platform/voice_mic_check_stub.dart';
import 'package:resonchat/platform/voice_recording_io.dart'
    if (dart.library.js_interop) 'package:resonchat/platform/voice_recording_web.dart';

/// Telegram discards clips shorter than ~700 ms.
const kMinVoiceMs = 700;

class VoiceClip {
  const VoiceClip({
    required this.bytes,
    required this.fileName,
    required this.mime,
    required this.duration,
  });

  final Uint8List bytes;
  final String fileName;
  final String mime;
  final Duration duration;
}

class _Codec {
  const _Codec({
    required this.encoder,
    required this.extension,
    required this.mime,
  });

  final AudioEncoder encoder;
  final String extension;
  final String mime;
}

/// Thin wrapper around [AudioRecorder] with temp-file / blob lifecycle.
class VoiceRecorder {
  VoiceRecorder() : _rec = AudioRecorder();

  final AudioRecorder _rec;
  String? _path;
  DateTime? _started;
  _Codec? _codec;
  var _active = false;

  bool get isRecording => _active;

  Duration get elapsed {
    final start = _started;
    if (start == null) return Duration.zero;
    return DateTime.now().difference(start);
  }

  /// Mic capture is available on mobile, desktop, and web browsers.
  static bool get isSupported => true;

  Future<bool> ensurePermission() => _rec.hasPermission();

  /// Soft-mute probe. See [MicMuteProbe]; never throws.
  static Future<MicMuteProbe> probeSystemMicMute() => probeDefaultMicMute();

  Future<_Codec> _pickCodec() async {
    if (!kIsWeb) {
      return const _Codec(
        encoder: AudioEncoder.aacLc,
        extension: 'm4a',
        mime: 'audio/mp4',
      );
    }
    // Browsers: Opus/WebM on Chrome/Firefox; WAV everywhere as fallback.
    if (await _rec.isEncoderSupported(AudioEncoder.opus)) {
      return const _Codec(
        encoder: AudioEncoder.opus,
        extension: 'webm',
        mime: 'audio/webm',
      );
    }
    return const _Codec(
      encoder: AudioEncoder.wav,
      extension: 'wav',
      mime: 'audio/wav',
    );
  }

  Future<void> start() async {
    if (_active) return;
    // Host CLIs only (AppImage does not bundle them). No-op off Linux.
    await ensureLinuxVoiceCaptureCli();
    final codec = await _pickCodec();
    final path = await prepareRecordingPath(codec.extension);
    await _rec.start(
      RecordConfig(
        encoder: codec.encoder,
        bitRate: 64000,
        sampleRate: 44100,
        numChannels: 1,
      ),
      path: path,
    );
    _path = path;
    _codec = codec;
    _started = DateTime.now();
    _active = true;
  }

  /// Stops and returns a clip, or null when cancelled / too short / empty.
  Future<VoiceClip?> stop({required bool send}) async {
    if (!_active) return null;
    _active = false;
    final started = _started;
    final codec = _codec;
    _started = null;
    _codec = null;
    final pathHint = _path;
    _path = null;

    String? stoppedPath;
    try {
      stoppedPath = await _rec.stop();
    } catch (_) {
      stoppedPath = pathHint;
    }
    // Web ignores the start path and returns a blob: URL from stop().
    final filePath = (stoppedPath != null && stoppedPath.isNotEmpty)
        ? stoppedPath
        : pathHint;
    if (filePath == null || filePath.isEmpty) return null;

    if (!send) {
      await discardRecordingPath(filePath);
      return null;
    }

    final duration = started == null
        ? Duration.zero
        : DateTime.now().difference(started);
    if (duration.inMilliseconds < kMinVoiceMs) {
      await discardRecordingPath(filePath);
      return null;
    }

    final bytes = await takeRecordingBytes(filePath);
    if (bytes == null || bytes.isEmpty) return null;

    final ext = codec?.extension ?? 'm4a';
    final mime = codec?.mime ?? 'audio/mp4';
    return VoiceClip(
      bytes: bytes,
      fileName: 'voice_${DateTime.now().millisecondsSinceEpoch}.$ext',
      mime: mime,
      duration: duration,
    );
  }

  Future<void> dispose() async {
    if (_active) {
      await stop(send: false);
    }
    await _rec.dispose();
  }
}
