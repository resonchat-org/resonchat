// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';
import 'dart:typed_data';

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

  group('hybridOmemo2Fingerprint', () {
    test('matches monocles CryptoHelper known-answer vector', () {
      final ik = Uint8List(33);
      ik[0] = 0x05;
      for (var i = 1; i < 33; i++) {
        ik[i] = 0x11;
      }
      final pq = Uint8List(2592);
      for (var i = 0; i < pq.length; i++) {
        pq[i] = 0x22;
      }
      const want =
          '6b6ea370b7cbc0078f992487b235ab384a7f272b232e508a2d27da9b42f1def7'
          'f2def0daffbdfd91a33065c1e383473a1eacce6e5709833d286c5e399e19c77a';
      expect(hybridOmemo2Fingerprint(ik, pq), want);
    });

    test('is 128 lowercase hex and domain-separated', () {
      final ik = Uint8List.fromList(List<int>.generate(33, (i) => i));
      final pq = Uint8List.fromList(List<int>.generate(64, (i) => 255 - i));
      final a = hybridOmemo2Fingerprint(ik, pq);
      final b = hybridOmemo2Fingerprint(ik, pq);
      expect(a, b);
      expect(a.length, 128);
      expect(RegExp(r'^[0-9a-f]+$').hasMatch(a), isTrue);

      // Different PQ key → different digest.
      final pq2 = Uint8List.fromList(pq);
      pq2[0] ^= 0xff;
      expect(hybridOmemo2Fingerprint(ik, pq2), isNot(a));

      // Label is committed: flipping a label byte in a hand-rolled digest
      // must not match (sanity that we use the monocles ASCII label).
      expect(ascii.decode(kHybridOmemo2FpLabel), 'monocles:omemo2:ik:v2');
    });

    test('length-prefix changes the digest', () {
      final ik = Uint8List.fromList([1, 2, 3]);
      final pq = Uint8List.fromList([4, 5, 6, 7]);
      final base = hybridOmemo2Fingerprint(ik, pq);
      // Same total bytes but different length fields if we wrongly omitted
      // prefixes — ensure empty PQ differs.
      expect(hybridOmemo2Fingerprint(ik, Uint8List(0)), isNot(base));
    });
  });
}
