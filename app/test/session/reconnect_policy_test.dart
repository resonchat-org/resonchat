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
      // Immediate first retry, then min(25 * 1.3^(n-1), 300).
      expect(policy.delaySecondsForAttempt(0), 0);
      expect(policy.delaySecondsForAttempt(1), 25);
      expect(policy.delaySecondsForAttempt(2), 33); // 25 * 1.3
      expect(policy.delaySecondsForAttempt(3), 42); // 25 * 1.3^2
      expect(policy.delaySecondsForAttempt(21), 300); // capped
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
    test(
      'a failed reconnect attempt keeps counting instead of restarting at 1',
      () async {
        final policy = MonoclesBackoffReconnectionPolicy(jitterSeconds: 0);
        await policy.setShouldReconnect(true);
        expect(await policy.canTriggerFailure(), isTrue);
        await policy.onFailure();
        expect(policy.attempt, 1);

        // moxxmpp calls reset() at the top of every `_connectImpl`, including
        // the one the policy itself starts. That must not turn the second
        // attempt back into "attempt 1" — the backoff has to keep growing.
        await policy.reset();
        expect(policy.attempt, 1);

        expect(await policy.canTriggerFailure(), isTrue);
        await policy.onFailure();
        expect(policy.attempt, 2);

        // A successful login clears it, so the next outage starts at 25 s.
        await policy.onSuccess();
        expect(policy.attempt, 0);
        expect(policy.isTimerRunning, isFalse);
      },
    );
  });
}
