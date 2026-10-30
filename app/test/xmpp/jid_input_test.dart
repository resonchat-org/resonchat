// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:test/test.dart';

import 'package:resonchat/xmpp/jid_input.dart';

void main() {
  group('jidOfUserInput (Conversations ofUserInput)', () {
    test('accepts entity bare, full, and domain JIDs', () {
      expect(jidOfUserInput('user@example.com'), 'user@example.com');
      expect(jidOfUserInput(' user@example.com '), 'user@example.com');
      expect(
        jidOfUserInput('bot@example.com/translator'),
        'bot@example.com/translator',
      );
      expect(
        jidOfUserInput('translation.example.com'),
        'translation.example.com',
      );
      expect(jidOfUserInput('localhost'), 'localhost');
      expect(jidOfUserInput('user@localhost'), 'user@localhost');
    });

    test('strips a trailing dot on the domain', () {
      expect(jidOfUserInput('user@example.com.'), 'user@example.com');
    });

    test('rejects empty resource and broken shapes', () {
      expect(jidOfUserInput(''), isNull);
      expect(jidOfUserInput('bot@example.com/'), isNull);
      expect(jidOfUserInput('user@'), isNull);
      expect(jidOfUserInput('@example.com'), isNull);
      expect(jidOfUserInput('user@ex@ample.com'), isNull);
      expect(jidOfUserInput('not a jid'), isNull);
      expect(jidOfUserInput('user@exam ple.com'), isNull);
    });

    test('accepts IPv4 domains', () {
      expect(jidOfUserInput('user@127.0.0.1'), 'user@127.0.0.1');
    });
  });

  group('completeJidCandidate defaults (entity bare)', () {
    test('needs localpart and rejects resources', () {
      expect(completeJidCandidate('a@b'), 'a@b');
      expect(completeJidCandidate('a@b.c'), 'a@b.c');
      expect(completeJidCandidate('user@example.com'), 'user@example.com');
      expect(completeJidCandidate('user@example.com/phone'), isNull);
      expect(completeJidCandidate('translation.example.com'), isNull);
      expect(completeJidCandidate('a@.c'), isNull);
    });
  });

  group('translation-provider shape', () {
    test('allows bare bot, component, and full JID', () {
      expect(
        completeJidCandidate(
          'bot@example.com',
          bareOnly: false,
          requireLocalpart: false,
        ),
        'bot@example.com',
      );
      expect(
        completeJidCandidate(
          'translation.example.com',
          bareOnly: false,
          requireLocalpart: false,
        ),
        'translation.example.com',
      );
      expect(
        completeJidCandidate(
          'bot@example.com/translator',
          bareOnly: false,
          requireLocalpart: false,
        ),
        'bot@example.com/translator',
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
          bareOnly: false,
          requireLocalpart: false,
          allowEmpty: true,
        ),
        isTrue,
      );
      expect(
        jidInputOk(
          'translation.example.com',
          bareOnly: false,
          requireLocalpart: false,
          allowEmpty: true,
        ),
        isTrue,
      );
    });
  });
}
