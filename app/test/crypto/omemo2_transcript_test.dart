// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:resonchat/crypto/omemo/omemo2_transcript.dart';

void main() {
  test('kemBinding known-answer (proto-XEP §4.9.1)', () {
    final binding = kemBinding(
      kemSpkId: 1,
      kemSpk: Uint8List.fromList(List<int>.filled(4, 0xAA)),
      oneTimeKeys: [
        KemOpkWire(
          id: 2,
          publicKey: Uint8List.fromList(List<int>.filled(3, 0xBB)),
        ),
        KemOpkWire(
          id: 3,
          publicKey: Uint8List.fromList(List<int>.filled(5, 0xCC)),
        ),
      ],
    );
    expect(
      binding.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
      '7f93e76279a9e5c4dffe34e20c809fb2d1ef8dafaebf26742725aa4a1eba4d0f'
      'fac892689509fa655a04fb8a6d6c0beff91f757ab714b6cb8c8cd3303c8c98f2',
    );
  });

  test('empty one-time keys use zero manifest', () {
    final a = kemBinding(
      kemSpkId: 1,
      kemSpk: Uint8List.fromList([1, 2, 3]),
      oneTimeKeys: const [],
    );
    final b = kemBinding(
      kemSpkId: 1,
      kemSpk: Uint8List.fromList([1, 2, 3]),
      oneTimeKeys: const [],
    );
    expect(a, b);
    expect(a.length, 64);
  });
}
