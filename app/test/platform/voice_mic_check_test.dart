// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';
import 'package:resonchat/platform/voice_mic_check_io.dart';

void main() {
  test('parseWpctlVolumeStdout reads mute and zero volume', () {
    expect(parseWpctlVolumeStdout('Volume: 1.00\n'), isFalse);
    expect(parseWpctlVolumeStdout('Volume: 0.50 [MUTED]\n'), isTrue);
    expect(parseWpctlVolumeStdout('Volume: 0.00\n'), isTrue);
    expect(parseWpctlVolumeStdout(''), isNull);
  });

  test('parsePactlMuteStdout reads Mute: yes/no', () {
    expect(parsePactlMuteStdout('Mute: yes\n'), isTrue);
    expect(parsePactlMuteStdout('Mute: no\n'), isFalse);
    expect(parsePactlMuteStdout(''), isNull);
  });

  test('parsePactlVolumeSilentStdout treats all-zero % as silent', () {
    expect(
      parsePactlVolumeSilentStdout(
        'Volume: front-left: 0 /   0% / -inf dB,   '
        'front-right: 0 /   0% / -inf dB',
      ),
      isTrue,
    );
    expect(
      parsePactlVolumeSilentStdout(
        'Volume: front-left: 65536 / 100% / 0.00 dB,   '
        'front-right: 65536 / 100% / 0.00 dB',
      ),
      isFalse,
    );
    expect(parsePactlVolumeSilentStdout('no percents here'), isNull);
  });

  test('probeDefaultMicMute does not throw', () async {
    final probe = await probeDefaultMicMute();
    expect(probe.muted, anyOf(isNull, isTrue, isFalse));
  });
}
