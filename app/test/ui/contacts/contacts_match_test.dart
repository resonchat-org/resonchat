// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:test/test.dart';

import 'package:resonchat/xmpp/jid_input.dart';

void main() {
  test('a jid suggestion needs a dot in the domain', () {
    expect(completeJidCandidate('a@b'), isNull);
    expect(completeJidCandidate('a@b.'), isNull);
    expect(completeJidCandidate('a@.c'), isNull);
    expect(completeJidCandidate('a@b.c'), 'a@b.c');
    expect(completeJidCandidate(' user@example.com '), 'user@example.com');
    expect(completeJidCandidate('user@example.com/phone'), isNull);
  });

  test('requireResource needs /resource on a dotted domain', () {
    expect(
      completeJidCandidate('user@example.com/phone', requireResource: true),
      'user@example.com/phone',
    );
    expect(
      completeJidCandidate('user@example.com', requireResource: true),
      isNull,
    );
  });
}
