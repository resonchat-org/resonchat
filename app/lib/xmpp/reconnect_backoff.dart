// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Conversations `XmppConnection.getTimeToNextAttempt` (no jitter).

import 'dart:math' as math;

/// Seconds until the next connect attempt may start.
///
/// Conversations formula:
/// - non-aggressive: `min(25 * 1.3^(additionalTime + attempt), 300) - connectionDuration`
/// - aggressive: `min(3 * 1.3^attempt, 60) - connectionDuration`
/// - `additionalTime = POLICY_VIOLATION ? 3 : 0`
///
/// Negative or zero means "connect now".
double timeToNextAttemptSeconds({
  required int attempt,
  required double connectionDurationSeconds,
  bool aggressive = false,
  bool policyViolation = false,
}) {
  final additionalTime = policyViolation ? 3 : 0;
  final raw = aggressive
      ? math.min(3 * math.pow(1.3, attempt).toDouble(), 60.0)
      : math.min(
          25 * math.pow(1.3, additionalTime + attempt).toDouble(),
          300.0,
        );
  return raw - connectionDurationSeconds;
}

/// Conversations connect / disco deadlines.
const Duration connectTimeout = Duration(seconds: 90);
const Duration connectDiscoTimeout = Duration(seconds: 20);

/// IQ ping schedule (Conversations Config, without LOW_PING_TIMEOUT / Push).
const Duration pingMaxInterval = Duration(seconds: 300);
const Duration pingMinInterval = Duration(seconds: 30);
const Duration pingTimeout = Duration(seconds: 15);
const Duration postConnectivityChangePingInterval = Duration(seconds: 30);

/// Whether an IQ ping is due given Conversations lastPacket / lastPing clocks.
bool pingIsDue({
  required DateTime now,
  required DateTime? lastPacketReceived,
  required DateTime? lastPingSent,
  required Duration interval,
}) {
  final lastActivity = _latest(lastPacketReceived, lastPingSent);
  if (lastActivity == null) return true;
  return now.difference(lastActivity) >= interval;
}

/// True when a ping was sent and no packet arrived within [timeout].
bool pingTimedOut({
  required DateTime now,
  required DateTime? lastPacketReceived,
  required DateTime? lastPingSent,
  Duration timeout = pingTimeout,
}) {
  final sent = lastPingSent;
  if (sent == null) return false;
  final received = lastPacketReceived;
  if (received != null && !received.isBefore(sent)) return false;
  return now.difference(sent) >= timeout;
}

DateTime? _latest(DateTime? a, DateTime? b) {
  if (a == null) return b;
  if (b == null) return a;
  return a.isAfter(b) ? a : b;
}
