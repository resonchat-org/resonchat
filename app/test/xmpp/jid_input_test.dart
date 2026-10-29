// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:test/test.dart';

import 'package:resonchat/xmpp/jid_input.dart';

void main() {
  group('completeJidCandidate bare', () {
    test('needs a dotted domain and rejects resources', () {
      expect(completeJidCandidate('a@b'), isNull);
      expect(completeJidCandidate('a@b.'), isNull);
      expect(completeJidCandidate('a@.c'), isNull);
      expect(completeJidCandidate('a@b.c'), 'a@b.c');
      expect(completeJidCandidate(' user@example.com '), 'user@example.com');
      expect(completeJidCandidate('user@example.com/phone'), isNull);
      expect(completeJidCandidate('user@ex@ample.com'), isNull);
    });
  });

  group('completeJidCandidate requireResource', () {
    test('requires non-empty resource after slash', () {
      expect(
        completeJidCandidate('bot@example.com', requireResource: true),
        isNull,
      );
      expect(
        completeJidCandidate('bot@example.com/', requireResource: true),
        isNull,
      );
      expect(
        completeJidCandidate(
          'bot@example.com/translator',
          requireResource: true,
        ),
        'bot@example.com/translator',
      );
      expect(completeJidCandidate('a@b/res', requireResource: true), isNull);
      expect(
        completeJidCandidate(
          ' translation.example.com ',
          requireResource: true,
        ),
        isNull,
      );
    });
  });

  group('jidInputOk', () {
    test('allowEmpty accepts blank', () {
      expect(jidInputOk('', allowEmpty: true), isTrue);
      expect(jidInputOk('  ', allowEmpty: true), isTrue);
      expect(jidInputOk('', allowEmpty: false), isFalse);
      expect(
        jidInputOk(
          'bot@example.com/t',
          requireResource: true,
          allowEmpty: true,
        ),
        isTrue,
      );
      expect(
        jidInputOk('bot@example.com', requireResource: true, allowEmpty: true),
        isFalse,
      );
    });
  });
}
