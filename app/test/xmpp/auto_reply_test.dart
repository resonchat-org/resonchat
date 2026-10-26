// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';

import 'package:resonchat/xmpp/auto_reply.dart';

AutoReplyRule _rule(String id, String pattern, String reply) {
  return AutoReplyRule(id: id, pattern: pattern, reply: reply);
}

void main() {
  test('first matching rule wins', () {
    final config = AutoReplyConfig(
      enabled: true,
      rules: [_rule('1', r'hello', 'first'), _rule('2', r'hello', 'second')],
    );
    expect(matchAutoReply(config, 'say hello')?.id, '1');
  });

  test('a later rule matches when the earlier one does not', () {
    final config = AutoReplyConfig(
      enabled: true,
      rules: [
        _rule('1', r'^ping$', 'pong'),
        _rule('2', r'help', 'what do you need?'),
      ],
    );
    expect(matchAutoReply(config, 'I need help')?.reply, 'what do you need?');
  });

  test('disabled config and invalid patterns do not match', () {
    final disabled = AutoReplyConfig(
      enabled: false,
      rules: [_rule('1', r'.+', 'yes')],
    );
    expect(matchAutoReply(disabled, 'anything'), isNull);

    final broken = AutoReplyConfig(
      enabled: true,
      rules: [_rule('1', r'(', 'nope'), _rule('2', r'ok', 'yes')],
    );
    expect(matchAutoReply(broken, 'ok')?.reply, 'yes');
    expect(isAutoReplyPatternValid(''), isFalse);
    expect(isAutoReplyPatternValid('('), isFalse);
    expect(matchAutoReply(broken, ''), isNull);
  });

  test('reply length counts a Han character as two', () {
    expect(autoReplyChars('a' * autoReplyMaxChars), autoReplyMaxChars);
    expect(autoReplyWithinLimit('a' * autoReplyMaxChars), isTrue);
    expect(autoReplyWithinLimit('a' * (autoReplyMaxChars + 1)), isFalse);

    expect(autoReplyChars('你' * 250), autoReplyMaxChars);
    expect(autoReplyWithinLimit('你' * 250), isTrue);
    expect(autoReplyWithinLimit('你' * 251), isFalse);
    expect(autoReplyChars('hello, 世界'), 11);
  });

  test('an over-long reply is skipped', () {
    final config = AutoReplyConfig(
      enabled: true,
      rules: [_rule('1', r'hi', '你' * 251), _rule('2', r'hi', 'ok')],
    );
    expect(matchAutoReply(config, 'hi')?.id, '2');
  });

  test('messages closer than one second keep only the first', () {
    final burst = AutoReplyBurst();
    final start = DateTime(2026, 1, 1, 12);
    expect(burst.tooSoon('a', start), isFalse);
    expect(
      burst.tooSoon('a', start.add(const Duration(milliseconds: 400))),
      isTrue,
    );
    // The ignored message moves the window. 900ms after it is still too
    // soon, even though it is more than a second after the first.
    expect(
      burst.tooSoon('a', start.add(const Duration(milliseconds: 1300))),
      isTrue,
    );

    final exact = AutoReplyBurst();
    expect(exact.tooSoon('a', start), isFalse);
    expect(exact.tooSoon('a', start.add(autoReplyMinGap)), isTrue);

    final open = AutoReplyBurst();
    expect(open.tooSoon('a', start), isFalse);
    expect(
      open.tooSoon('a', start.add(const Duration(milliseconds: 1001))),
      isFalse,
    );
    expect(open.tooSoon('b', start), isFalse);
  });

  test('config json keeps rule order', () {
    final config = AutoReplyConfig(
      enabled: true,
      rules: [_rule('a', r'^a', 'A'), _rule('b', r'^b', 'B')],
    );
    final raw = config.toJson();
    final rules = (raw['rules']! as List)
        .map(AutoReplyRule.fromJson)
        .whereType<AutoReplyRule>()
        .toList();
    expect(rules.map((rule) => rule.id), ['a', 'b']);
    expect(raw['enabled'], isTrue);
  });
}
