// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:test/test.dart';

import 'package:resonchat/xmpp/jid_input.dart';

void main() {
  test('a contact JID is an entity bare address', () {
    expect(completeJidCandidate('a@b'), 'a@b');
    expect(completeJidCandidate('a@.c'), isNull);
    expect(completeJidCandidate('a@b.c'), 'a@b.c');
    expect(completeJidCandidate(' user@example.com '), 'user@example.com');
    expect(completeJidCandidate('user@example.com/phone'), isNull);
    expect(completeJidCandidate('translation.example.com'), isNull);
  });

  test('ofUserInput still accepts a full JID when bareOnly is off', () {
    expect(
      completeJidCandidate(
        'user@example.com/phone',
        bareOnly: false,
        requireLocalpart: false,
      ),
      'user@example.com/phone',
    );
    expect(jidOfUserInput('user@example.com'), 'user@example.com');
  });
}
