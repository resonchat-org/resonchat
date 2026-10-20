// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// monocles backoff schedule for automatic reconnect after TCP/stream loss.

import 'package:test/test.dart';

import 'package:resonchat/xmpp/reconnect_policy.dart';

void main() {
  group('MonoclesBackoffReconnectionPolicy', () {
    test('delay matches monocles getTimeToNextAttempt (non-aggressive)', () {
      final policy = MonoclesBackoffReconnectionPolicy(jitterSeconds: 0);
      // min(25 * 1.3^n, 300)
      expect(policy.delaySecondsForAttempt(0), 25);
      expect(policy.delaySecondsForAttempt(1), 33); // 25 * 1.3
      expect(policy.delaySecondsForAttempt(2), 42); // 25 * 1.3^2
      expect(policy.delaySecondsForAttempt(20), 300); // capped
    });

    test(
      'onFailure schedules and onSuccess resets the attempt counter',
      () async {
        final policy = MonoclesBackoffReconnectionPolicy(jitterSeconds: 0);
        await policy.setShouldReconnect(true);
        var reconnects = 0;
        policy.register(() async {
          reconnects++;
          await policy.reset();
        });

        expect(await policy.canTriggerFailure(), isTrue);
        await policy.onFailure();
        expect(policy.attempt, 1);
        expect(policy.isTimerRunning, isTrue);

        await policy.onSuccess();
        expect(policy.attempt, 0);
        expect(policy.isTimerRunning, isFalse);
        expect(reconnects, 0);
      },
    );
  });
}
