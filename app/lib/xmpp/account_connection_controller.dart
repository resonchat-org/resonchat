// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Single scheduler for connect / IQ ping / backoff — Conversations
// `manageAccountConnectionStates` / `processAccountState`.

import 'dart:async';

import 'package:logging/logging.dart';

import 'package:resonchat/xmpp/account_connection_state.dart';
import 'package:resonchat/xmpp/reconnect_backoff.dart';

/// Per-account runtime owned by [AccountConnectionController].
class AccountConnectionRuntime {
  AccountConnectionState state = AccountConnectionState.offline;
  int attempt = 0;
  DateTime? connectStartedAt;
  DateTime? lastPacketReceived;
  DateTime? lastPingSent;
  bool pingInFlight = false;
  Timer? dueTimer;
}

/// Hooks the controller needs from the hub / XmppService.
typedef AccountConnectFn = Future<bool> Function(String accountId);
typedef AccountDisconnectFn = Future<void> Function(String accountId);
typedef AccountSendPingFn = Future<bool> Function(String accountId);
typedef AccountIsEnabledFn = bool Function(String accountId);
typedef AccountIdsFn = Iterable<String> Function();

/// Conversations `JingleManager.hasJingleRtpConnection` — false until calls land.
typedef HasActiveJingleRtpCallFn = bool Function(String accountId);

/// Conversations `scheduleWakeUpCall` (AlarmManager). No-op on desktop / tests.
abstract class ConnectionWakeScheduler {
  void setOnWake(void Function(int requestCode)? callback);
  Future<void> schedule(Duration delay, int requestCode);
  Future<void> cancel(int requestCode);
}

class NoopWakeScheduler implements ConnectionWakeScheduler {
  @override
  void setOnWake(void Function(int requestCode)? callback) {}

  @override
  Future<void> schedule(Duration delay, int requestCode) async {}

  @override
  Future<void> cancel(int requestCode) async {}
}

/// Unique entry for reconnect and liveness (replaces hub + moxxmpp dual clocks).
class AccountConnectionController {
  AccountConnectionController({
    required this.connectAccount,
    required this.disconnectAccount,
    required this.sendPing,
    required this.isEnabled,
    required this.accountIds,
    this.hasActiveJingleRtpCall = _noJingle,
    ConnectionWakeScheduler? wakeScheduler,
    this.now = DateTime.now,
    this.foreground = false,
  }) : wakeScheduler = wakeScheduler ?? NoopWakeScheduler();

  static bool _noJingle(String _) => false;

  final AccountConnectFn connectAccount;
  final AccountDisconnectFn disconnectAccount;
  final AccountSendPingFn sendPing;
  final AccountIsEnabledFn isEnabled;
  final AccountIdsFn accountIds;

  /// Aggressive reconnect while a voice/video call is up (Conversations).
  final HasActiveJingleRtpCallFn hasActiveJingleRtpCall;
  final ConnectionWakeScheduler wakeScheduler;
  final DateTime Function() now;

  /// When true, ping interval uses [pingMinInterval] (UI / FG activity).
  bool foreground;

  final _log = Logger('AccountConnectionController');
  final Map<String, AccountConnectionRuntime> _runtimes = {};
  Timer? _tick;
  Timer? _postConnectivityPing;
  bool _disposed = false;

  AccountConnectionRuntime runtime(String accountId) =>
      _runtimes.putIfAbsent(accountId, AccountConnectionRuntime.new);

  AccountConnectionState stateOf(String accountId) => runtime(accountId).state;

  /// Starts the periodic due check (≈15 s, half of [pingTimeout]).
  ///
  /// On Android, [AndroidKeepAlive.scheduleWake] (AlarmManager) is also armed
  /// for exact due times — Conversations `scheduleWakeUpCall`.
  void start() {
    wakeScheduler.setOnWake((_) {
      if (!_disposed) processAllAccounts();
    });
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 15), (_) {
      processAllAccounts();
    });
  }

  void dispose() {
    _disposed = true;
    wakeScheduler.setOnWake(null);
    _tick?.cancel();
    _tick = null;
    _postConnectivityPing?.cancel();
    _postConnectivityPing = null;
    for (final entry in _runtimes.entries) {
      entry.value.dueTimer?.cancel();
      unawaited(wakeScheduler.cancel(entry.key.hashCode));
    }
    _runtimes.clear();
  }

  void removeAccount(String accountId) {
    final r = _runtimes.remove(accountId);
    r?.dueTimer?.cancel();
    unawaited(wakeScheduler.cancel(accountId.hashCode));
  }

  void _armDue(String accountId, Duration delay) {
    final r = runtime(accountId);
    r.dueTimer?.cancel();
    r.dueTimer = Timer(delay, () {
      if (_disposed) return;
      processAccountState(accountId);
    });
    // Conversations AlarmManager wake — keeps due work alive under Doze.
    unawaited(wakeScheduler.schedule(delay, accountId.hashCode));
  }

  /// UI / process in foreground → Conversations `isUiAction` (PING_MIN_INTERVAL).
  void setForeground(bool value) {
    if (foreground == value) return;
    foreground = value;
    if (value) processAllAccounts();
  }

  /// Network became available: process immediately + Conversations 30 s delayed ping.
  void onConnectivityRestored() {
    for (final id in accountIds()) {
      if (!isEnabled(id)) continue;
      final r = runtime(id);
      // A network that just returned makes a prior "unreachable" wait obsolete —
      // try immediately (Conversations CONNECTIVITY_ACTION).
      if (r.state == AccountConnectionState.noInternet ||
          r.state == AccountConnectionState.unreachable) {
        r.attempt = 0;
        r.connectStartedAt = null;
        setState(id, AccountConnectionState.offline);
      }
    }
    processAllAccounts();
    _postConnectivityPing?.cancel();
    _postConnectivityPing = Timer(postConnectivityChangePingInterval, () {
      for (final id in accountIds()) {
        if (!isEnabled(id)) continue;
        final r = runtime(id);
        if (r.state == AccountConnectionState.online) {
          // Force a ping candidate by clearing the "recent activity" window.
          r.lastPingSent = null;
        }
      }
      processAllAccounts();
    });
  }

  void notifyPacketReceived(String accountId) {
    final r = runtime(accountId);
    r.lastPacketReceived = now();
  }

  void setState(String accountId, AccountConnectionState next) {
    final r = runtime(accountId);
    if (r.state == next) return;
    _log.fine('account $accountId ${r.state.name} → ${next.name}');
    r.state = next;
    if (next == AccountConnectionState.connecting) {
      // Fresh attempt — Conversations resets lastConnectionStarted here.
      r.connectStartedAt = now();
    }
    if (next == AccountConnectionState.online) {
      r.attempt = 0;
      r.connectStartedAt = null;
      r.lastPacketReceived = now();
      r.lastPingSent = null;
      r.pingInFlight = false;
    }
    // Keep [connectStartedAt] after a failed attempt so getTimeToNextAttempt
    // can subtract connectionDuration (Conversations XmppConnection).
  }

  /// Records a failed connect / stream loss and schedules the next attempt.
  void onConnectionLost(
    String accountId,
    AccountConnectionState next, {
    bool incrementAttempt = true,
  }) {
    final r = runtime(accountId);
    if (incrementAttempt &&
        next != AccountConnectionState.unauthorized &&
        next != AccountConnectionState.incompatibleServer) {
      r.attempt++;
    }
    // Do not clear connectStartedAt — backoff uses connectionDuration.
    r.pingInFlight = false;
    setState(accountId, next);
    processAccountState(accountId);
  }

  void processAllAccounts() {
    if (_disposed) return;
    for (final id in accountIds()) {
      processAccountState(id);
    }
  }

  void processAccountState(String accountId) {
    if (_disposed) return;
    if (!isEnabled(accountId)) return;
    final r = runtime(accountId);
    final current = r.state;

    if (current == AccountConnectionState.online) {
      unawaited(_processOnline(accountId, r));
      return;
    }

    if (current == AccountConnectionState.connecting) {
      final started = r.connectStartedAt;
      if (started != null && now().difference(started) >= connectTimeout) {
        _log.warning('account $accountId CONNECT_TIMEOUT');
        unawaited(disconnectAccount(accountId));
        onConnectionLost(
          accountId,
          AccountConnectionState.connectionTimeout,
          incrementAttempt: true,
        );
      }
      return;
    }

    if (!attemptReconnect(current)) return;

    if (reconnectImmediately(current)) {
      unawaited(_tryConnect(accountId, r));
      return;
    }

    final duration = r.connectStartedAt == null
        ? 0.0
        : now().difference(r.connectStartedAt!).inMilliseconds / 1000.0;
    final wait = timeToNextAttemptSeconds(
      attempt: r.attempt,
      connectionDurationSeconds: duration,
      aggressive: isAggressiveReconnect(
        current,
        hasActiveJingleRtpCall: hasActiveJingleRtpCall(accountId),
      ),
      policyViolation: isPolicyViolationBackoff(current),
    );
    if (wait <= 0) {
      unawaited(_tryConnect(accountId, r));
      return;
    }
    _armDue(accountId, Duration(milliseconds: (wait * 1000).ceil()));
  }

  Future<void> _processOnline(
    String accountId,
    AccountConnectionRuntime r,
  ) async {
    final n = now();
    if (pingTimedOut(
      now: n,
      lastPacketReceived: r.lastPacketReceived,
      lastPingSent: r.lastPingSent,
    )) {
      _log.warning('account $accountId ping timeout; forcing reconnect');
      await disconnectAccount(accountId);
      onConnectionLost(
        accountId,
        AccountConnectionState.offline,
        incrementAttempt: true,
      );
      return;
    }

    final interval = foreground ? pingMinInterval : pingMaxInterval;
    if (!pingIsDue(
      now: n,
      lastPacketReceived: r.lastPacketReceived,
      lastPingSent: r.lastPingSent,
      interval: interval,
    )) {
      // Arm wake for the remaining idle window (Conversations scheduleWakeUpCall).
      final last = r.lastPacketReceived ?? r.lastPingSent ?? n;
      final remaining = interval - n.difference(last);
      if (remaining > Duration.zero) {
        _armDue(accountId, remaining);
      }
      return;
    }
    if (r.pingInFlight) return;
    r.pingInFlight = true;
    r.lastPingSent = n;
    // Wake before pingTimeout so a dead socket is noticed under Doze.
    _armDue(accountId, pingTimeout);
    final ok = await sendPing(accountId);
    r.pingInFlight = false;
    if (!ok) {
      // sendPing already timed out or the socket is gone — treat as offline.
      if (runtime(accountId).state == AccountConnectionState.online) {
        await disconnectAccount(accountId);
        onConnectionLost(
          accountId,
          AccountConnectionState.offline,
          incrementAttempt: true,
        );
      }
    } else {
      notifyPacketReceived(accountId);
    }
  }

  Future<void> _tryConnect(String accountId, AccountConnectionRuntime r) async {
    if (r.state == AccountConnectionState.connecting) return;
    setState(accountId, AccountConnectionState.connecting);
    final ok = await connectAccount(accountId);
    if (_disposed) return;
    if (ok) {
      setState(accountId, AccountConnectionState.online);
    }
    // Failures must call onConnectionLost from the connect path so the
    // classified AccountConnectionState is preserved.
  }

  /// User-initiated "try again" / cold start: force offline then process.
  void requestConnect(String accountId) {
    final r = runtime(accountId);
    r.attempt = 0;
    r.connectStartedAt = null;
    setState(accountId, AccountConnectionState.offline);
    processAccountState(accountId);
  }
}
