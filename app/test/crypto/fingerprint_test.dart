// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:test/test.dart';

import 'package:resonchat/crypto/fingerprint.dart';

void main() {
  group('formatFingerprint', () {
    test('strips leading 05 from 66-char classical serialize hex', () {
      final raw = '05${'ab' * 32}';
      expect(raw.length, 66);
      final pretty = formatFingerprint(raw);
      expect(pretty.startsWith('05'), isFalse);
      expect(pretty.replaceAll(' ', '').length, 64);
    });

    test('does not strip hybrid SHA3-512 hex', () {
      final hybrid = 'a' * 128;
      expect(formatFingerprint(hybrid).replaceAll(' ', ''), hybrid);
    });
  });
}
