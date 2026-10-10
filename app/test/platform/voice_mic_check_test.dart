// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';
import 'package:resonchat/platform/voice_mic_check_io.dart';

void main() {
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

  test('isDefaultMicMuted does not throw without PulseAudio', () async {
    // CI runners often lack pactl; the check must return null, not throw.
    final disabled = await isDefaultMicMuted();
    expect(disabled, anyOf(isNull, isTrue, isFalse));
  });
}
