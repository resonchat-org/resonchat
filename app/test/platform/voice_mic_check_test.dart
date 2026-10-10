// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:resonchat/platform/voice_mic_check_io.dart';

void main() {
  test('Linux treats mute or 0% volume as disabled', () async {
    final disabled = await isDefaultMicMuted();
    final mute = await Process.run('pactl', [
      'get-source-mute',
      '@DEFAULT_SOURCE@',
    ]);
    final vol = await Process.run('pactl', [
      'get-source-volume',
      '@DEFAULT_SOURCE@',
    ]);
    final muted = (mute.stdout as String).toLowerCase().contains('yes');
    final percents = RegExp(r'(\d+)\s*%')
        .allMatches(vol.stdout as String)
        .map((m) => int.parse(m.group(1)!))
        .toList();
    final zero = percents.isNotEmpty && percents.every((p) => p == 0);
    expect(disabled, muted || zero);
  }, skip: !Platform.isLinux);
}
