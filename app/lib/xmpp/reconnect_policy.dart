// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Automatic reconnect after recoverable TCP / stream loss.
// Schedule mirrors monocles `XmppConnection.getTimeToNextAttempt`.

import 'dart:async';
import 'dart:math';

import 'package:logging/logging.dart';
import 'package:moxxmpp/moxxmpp.dart';

/// monocles-style exponential backoff after a recoverable stream/TCP loss.
///
/// Formula from `XmppConnection.getTimeToNextAttempt` (non-aggressive):
/// `min(25 * 1.3^attempt, 300)` seconds, plus a small random jitter so many
/// clients recovering from the same outage do not stampede the server.
class MonoclesBackoffReconnectionPolicy extends ReconnectionPolicy {
  MonoclesBackoffReconnectionPolicy({
    this.baseSeconds = 25,
    this.factor = 1.3,
    this.maxSeconds = 300,
    this.jitterSeconds = 2,
  });

  final int baseSeconds;
  final double factor;
  final int maxSeconds;
  final int jitterSeconds;

  final Logger _log = Logger('MonoclesBackoffReconnectionPolicy');
  Timer? _timer;
  int _attempt = 0;

  /// How many failures have been scheduled since the last success.
  int get attempt => _attempt;

  bool get isTimerRunning => _timer != null;

  /// Delay before the next try for [attemptIndex] (0-based), without jitter.
  int delaySecondsForAttempt(int attemptIndex) {
    final raw = baseSeconds * _pow(factor, attemptIndex);
    final capped = raw > maxSeconds ? maxSeconds : raw.round();
    return capped < 1 ? 1 : capped;
  }

  static double _pow(double base, int exp) {
    var out = 1.0;
    for (var i = 0; i < exp; i++) {
      out *= base;
    }
    return out;
  }

  @override
  Future<void> reset() async {
    _timer?.cancel();
    _timer = null;
    _attempt = 0;
    await super.reset();
  }

  @override
  Future<void> onSuccess() async {
    _log.fine('reconnect succeeded; resetting backoff');
    await reset();
  }

  @override
  Future<void> onFailure() async {
    final delay = delaySecondsForAttempt(_attempt);
    final jitter = jitterSeconds <= 0 ? 0 : Random().nextInt(jitterSeconds + 1);
    final wait = delay + jitter;
    _log.info(
      'connection lost; reconnect attempt ${_attempt + 1} in ${wait}s '
      '(base=${delay}s + jitter=${jitter}s)',
    );
    _attempt++;
    _timer?.cancel();
    _timer = Timer(Duration(seconds: wait), () {
      unawaited(_onTimerElapsed());
    });
  }

  Future<void> _onTimerElapsed() async {
    _timer = null;
    if (!(await getShouldReconnect())) {
      _log.fine('should not reconnect; skipping');
      await reset();
      return;
    }
    final reconnect = performReconnect;
    if (reconnect == null) {
      _log.warning('no performReconnect registered');
      await reset();
      return;
    }
    await reconnect();
  }
}
