// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:resonchat/ui/contacts/contacts_match.dart';
import 'package:test/test.dart';

void main() {
  test('a jid suggestion needs a dot in the domain', () {
    expect(completeJidCandidate('a@b'), isNull);
    expect(completeJidCandidate('a@b.'), isNull);
    expect(completeJidCandidate('a@.c'), isNull);
    expect(completeJidCandidate('a@b.c'), 'a@b.c');
    expect(completeJidCandidate(' user@example.com '), 'user@example.com');
    expect(completeJidCandidate('user@example.com/phone'), isNull);
  });
}
