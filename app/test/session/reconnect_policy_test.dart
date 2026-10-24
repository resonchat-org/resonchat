// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Conversations getTimeToNextAttempt + ping due / timeout helpers.

import 'package:test/test.dart';

import 'package:resonchat/xmpp/reconnect_backoff.dart';

void main() {
  group('timeToNextAttemptSeconds', () {
    test('non-aggressive matches Conversations formula', () {
      // min(25 * 1.3^attempt, 300) - connectionDuration
      expect(
        timeToNextAttemptSeconds(attempt: 0, connectionDurationSeconds: 0),
        closeTo(25, 0.01),
      );
      expect(
        timeToNextAttemptSeconds(attempt: 1, connectionDurationSeconds: 0),
        closeTo(25 * 1.3, 0.01),
      );
      expect(
        timeToNextAttemptSeconds(attempt: 2, connectionDurationSeconds: 0),
        closeTo(25 * 1.3 * 1.3, 0.01),
      );
      expect(
        timeToNextAttemptSeconds(attempt: 20, connectionDurationSeconds: 0),
        300,
      );
    });

    test('subtracts connectionDuration (may go negative → connect now)', () {
      expect(
        timeToNextAttemptSeconds(attempt: 0, connectionDurationSeconds: 30),
        closeTo(-5, 0.01),
      );
    });

    test('policyViolation adds +3 to the exponent', () {
      final normal = timeToNextAttemptSeconds(
        attempt: 0,
        connectionDurationSeconds: 0,
      );
      final policy = timeToNextAttemptSeconds(
        attempt: 0,
        connectionDurationSeconds: 0,
        policyViolation: true,
      );
      expect(policy, closeTo(25 * 1.3 * 1.3 * 1.3, 0.01));
      expect(policy, greaterThan(normal));
    });

    test('aggressive uses 3 * 1.3^attempt capped at 60', () {
      expect(
        timeToNextAttemptSeconds(
          attempt: 0,
          connectionDurationSeconds: 0,
          aggressive: true,
        ),
        closeTo(3, 0.01),
      );
      expect(
        timeToNextAttemptSeconds(
          attempt: 40,
          connectionDurationSeconds: 0,
          aggressive: true,
        ),
        60,
      );
    });
  });

  group('pingIsDue / pingTimedOut', () {
    final t0 = DateTime.utc(2024, 1, 1, 12);

    test('ping is due when idle longer than interval', () {
      expect(
        pingIsDue(
          now: t0.add(const Duration(seconds: 301)),
          lastPacketReceived: t0,
          lastPingSent: null,
          interval: pingMaxInterval,
        ),
        isTrue,
      );
      expect(
        pingIsDue(
          now: t0.add(const Duration(seconds: 100)),
          lastPacketReceived: t0,
          lastPingSent: null,
          interval: pingMaxInterval,
        ),
        isFalse,
      );
    });

    test('traffic postpones the next ping', () {
      final pingAt = t0.add(const Duration(seconds: 200));
      final packetAt = t0.add(const Duration(seconds: 250));
      expect(
        pingIsDue(
          now: t0.add(const Duration(seconds: 280)),
          lastPacketReceived: packetAt,
          lastPingSent: pingAt,
          interval: pingMaxInterval,
        ),
        isFalse,
      );
    });

    test('ping times out when no packet after send', () {
      final sent = t0;
      expect(
        pingTimedOut(
          now: t0.add(const Duration(seconds: 16)),
          lastPacketReceived: null,
          lastPingSent: sent,
        ),
        isTrue,
      );
      expect(
        pingTimedOut(
          now: t0.add(const Duration(seconds: 16)),
          lastPacketReceived: t0.add(const Duration(seconds: 1)),
          lastPingSent: sent,
        ),
        isFalse,
      );
    });
  });
}
