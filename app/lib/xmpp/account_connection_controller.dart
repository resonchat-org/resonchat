// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Single scheduler for connect / IQ ping / backoff — Conversations
// `manageAccountConnectionStates` / `processAccountState`.
//
// The controller owns one timer and one connect attempt per account. Every
// asynchronous result carries the runtime generation it was started with, so a
// late socket failure (or a success that lands after the controller already
// gave up) can never overwrite a newer state. This is the piece that keeps a
// flapping connection from starting two sockets at once.

import 'dart:async';

import 'package:logging/logging.dart';

import 'package:resonchat/xmpp/account_connection_state.dart';
import 'package:resonchat/xmpp/reconnect_backoff.dart';

/// Per-account runtime owned by [AccountConnectionController].
class AccountConnectionRuntime {
  AccountConnectionState state = AccountConnectionState.offline;
  int attempt = 0;

  /// Invalidates asynchronous work started before a state change / timeout.
  int generation = 0;

  DateTime? connectStartedAt;
  DateTime? lastPacketReceived;
  DateTime? lastPingSent;

  /// One connect future owns this flag until it really returns, even after a
  /// timeout has already invalidated its result. No second socket may start
  /// while it is set.
  bool connectInFlight = false;
  bool pingInFlight = false;
  bool pingNow = false;

  /// A ping/connect failure is already tearing the socket down.
  bool lossInProgress = false;
  bool connectTimeoutInFlight = false;

  Timer? dueTimer;
}

/// Hooks the controller needs from the hub / XmppService.
typedef AccountConnectFn = Future<bool> Function(String accountId);
typedef AccountDisconnectFn = Future<void> Function(String accountId);
typedef AccountSendPingFn = Future<bool> Function(String accountId);
typedef AccountIsEnabledFn = bool Function(String accountId);
typedef AccountIdsFn = Iterable<String> Function();

/// Resolves the state for a failed [AccountConnectFn] after it returned false.
///
/// The hub reads `XmppService.lastFailure`; keeping the classification out of
/// the connect path means the controller still owns the retry decision.
typedef AccountConnectFailureStateFn = AccountConnectionState Function(
  String accountId,
);

/// Fallback network probe used while the controller believes it is offline.
/// Connectivity plugins occasionally miss a change; a 15 s recheck keeps a
/// false "no internet" from parking an account forever.
typedef AccountNetworkCheckFn = Future<bool> Function();

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
    this.connectFailureState,
    this.checkNetwork,
    this.hasActiveJingleRtpCall = _noJingle,
    ConnectionWakeScheduler? wakeScheduler,
    this.now = DateTime.now,
    this.foreground = false,
    this.disconnectTimeout = const Duration(seconds: 10),
  }) : wakeScheduler = wakeScheduler ?? NoopWakeScheduler();

  static bool _noJingle(String _) => false;

  final AccountConnectFn connectAccount;
  final AccountDisconnectFn disconnectAccount;
  final AccountSendPingFn sendPing;
  final AccountIsEnabledFn isEnabled;
  final AccountIdsFn accountIds;
  final AccountConnectFailureStateFn? connectFailureState;
  final AccountNetworkCheckFn? checkNetwork;

  /// Aggressive reconnect while a voice/video call is up (Conversations).
  final HasActiveJingleRtpCallFn hasActiveJingleRtpCall;
  final ConnectionWakeScheduler wakeScheduler;
  final DateTime Function() now;

  /// Bound on teardown. A socket that will not close must not freeze the
  /// scheduler; the retry can still proceed.
  final Duration disconnectTimeout;

  /// When true, ping interval uses [pingMinInterval] (UI / FG activity).
  bool foreground;

  /// Last network availability reported by the platform. Conversations
  /// `hasInternetConnection()` gates reconnect attempts, so an offline device
  /// does not spin through the backoff.
  bool _networkAvailable = true;
  bool get networkAvailable => _networkAvailable;

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
      if (_disposed) return;
      if (!_networkAvailable && checkNetwork != null) {
        unawaited(_recheckNetwork());
      }
      processAllAccounts();
    });
  }

  Future<void> _recheckNetwork() async {
    final check = checkNetwork;
    if (check == null || _disposed || _networkAvailable) return;
    try {
      if (await check() && !_disposed && !_networkAvailable) {
        onConnectivityRestored();
      }
    } catch (_) {
      // A probe failure is not evidence of connectivity either way.
    }
  }

  void dispose() {
    _disposed = true;
    wakeScheduler.setOnWake(null);
    _tick?.cancel();
    _tick = null;
    _postConnectivityPing?.cancel();
    _postConnectivityPing = null;
    for (final entry in _runtimes.entries) {
      entry.value.generation++;
      entry.value.dueTimer?.cancel();
      unawaited(wakeScheduler.cancel(entry.key.hashCode));
    }
    _runtimes.clear();
  }

  void removeAccount(String accountId) {
    final r = _runtimes.remove(accountId);
    if (r != null) {
      // A connect future may still be in flight. Bumping the generation makes
      // its late success/failure harmless.
      r.generation++;
      r.dueTimer?.cancel();
    }
    unawaited(wakeScheduler.cancel(accountId.hashCode));
  }

  void _cancelDue(AccountConnectionRuntime r) {
    r.dueTimer?.cancel();
    r.dueTimer = null;
  }

  void _armDue(String accountId, Duration delay) {
    final r = runtime(accountId);
    _cancelDue(r);
    final wait = delay.isNegative ? Duration.zero : delay;
    r.dueTimer = Timer(wait, () {
      if (_disposed) return;
      processAccountState(accountId);
    });
    // Conversations AlarmManager wake — keeps due work alive under Doze.
    // Sub-second work is left to the Dart timer; an alarm that small only
    // produces churn.
    if (wait >= const Duration(seconds: 1)) {
      unawaited(wakeScheduler.schedule(wait, accountId.hashCode));
    } else {
      unawaited(wakeScheduler.cancel(accountId.hashCode));
    }
  }

  /// Schedules a run for this account without displacing a pending retry.
  void _scheduleProcess(String accountId) {
    final r = runtime(accountId);
    if (r.dueTimer?.isActive ?? false) return;
    _armDue(accountId, Duration.zero);
  }

  /// UI / process in foreground → Conversations `isUiAction` (PING_MIN_INTERVAL).
  void setForeground(bool value) {
    if (foreground == value) return;
    foreground = value;
    if (value) processAllAccounts();
  }

  /// Network availability callback. Kept explicit so the controller can stop
  /// retrying on an offline device, exactly like Conversations
  /// `hasInternetConnection()`.
  void setNetworkAvailable(bool available) {
    if (_networkAvailable == available) return;
    if (available) {
      onConnectivityRestored();
    } else {
      onConnectivityLost();
    }
  }

  /// Network became available: process immediately + Conversations 30 s delayed
  /// ping.
  void onConnectivityRestored() {
    if (_disposed) return;
    _networkAvailable = true;
    for (final id in accountIds()) {
      if (!isEnabled(id)) continue;
      final r = runtime(id);
      if (r.state == AccountConnectionState.online ||
          r.state == AccountConnectionState.connecting) {
        continue;
      }
      // A network that just returned makes a prior "unreachable" wait obsolete
      // — try immediately (Conversations CONNECTIVITY_ACTION).
      if (attemptReconnect(r.state)) {
        r.attempt = 0;
        r.connectStartedAt = null;
        r.lastPingSent = null;
        if (r.state != AccountConnectionState.offline) {
          setState(id, AccountConnectionState.offline);
        }
      }
    }
    processAllAccounts();
    _postConnectivityPing?.cancel();
    _postConnectivityPing = Timer(postConnectivityChangePingInterval, () {
      if (_disposed) return;
      for (final id in accountIds()) {
        if (!isEnabled(id)) continue;
        final r = runtime(id);
        if (r.state == AccountConnectionState.online) {
          // Conversations sends a ping on CONNECTIVITY_ACTION regardless of
          // the last activity window.
          r.pingNow = true;
        }
      }
      processAllAccounts();
    });
  }

  /// Network disappeared. Stop the retry clock and show NO_INTERNET until the
  /// platform tells us it is back. The socket may still be alive for a moment;
  /// it is torn down by the next connect or by its own read error.
  void onConnectivityLost() {
    if (_disposed || !_networkAvailable) return;
    _networkAvailable = false;
    _postConnectivityPing?.cancel();
    _postConnectivityPing = null;
    for (final id in accountIds()) {
      if (!isEnabled(id)) continue;
      final r = runtime(id);
      if (r.state == AccountConnectionState.unauthorized ||
          r.state == AccountConnectionState.incompatibleServer) {
        continue;
      }
      if (r.state == AccountConnectionState.noInternet) continue;
      // Invalidate a connect that is waiting on a network that just vanished.
      final wasConnecting =
          r.state == AccountConnectionState.connecting || r.connectInFlight;
      r.generation++;
      r.pingInFlight = false;
      r.pingNow = false;
      _cancelDue(r);
      setState(id, AccountConnectionState.noInternet);
      if (wasConnecting) {
        // The pending socket may be stuck in TCP/TLS against the old network.
        // Abort it now so connectivity returning does not wait for the 90 s
        // connect deadline; the connect future still owns the mutex, so no
        // overlapping socket can start.
        unawaited(_safeDisconnect(id));
      }
    }
  }

  void notifyPacketReceived(String accountId) {
    if (_disposed) return;
    final r = runtime(accountId);
    r.lastPacketReceived = now();
  }

  void setState(String accountId, AccountConnectionState next) {
    if (_disposed) return;
    final r = runtime(accountId);
    if (r.state == next) return;
    _log.fine('account $accountId ${r.state.name} → ${next.name}');
    r.state = next;
    if (next == AccountConnectionState.connecting) {
      // Fresh attempt — Conversations resets lastConnectionStarted here.
      r.connectStartedAt = now();
      r.pingInFlight = false;
      r.pingNow = false;
      _cancelDue(r);
    } else if (next == AccountConnectionState.online) {
      r.attempt = 0;
      r.connectStartedAt = null;
      r.lastPacketReceived = now();
      r.lastPingSent = null;
      r.pingInFlight = false;
      r.pingNow = false;
      r.lossInProgress = false;
      r.connectTimeoutInFlight = false;
      _cancelDue(r);
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
    if (_disposed || !isEnabled(accountId)) return;
    final r = runtime(accountId);
    // A duplicate loss while the same retry is already armed must not add a
    // second attempt or reset the backoff.
    if (r.state == next && (r.dueTimer?.isActive ?? false)) return;

    r.generation++;
    r.pingInFlight = false;
    r.pingNow = false;
    r.lastPingSent = null;
    _cancelDue(r);
    if (incrementAttempt &&
        next != AccountConnectionState.offline &&
        next != AccountConnectionState.unauthorized &&
        next != AccountConnectionState.incompatibleServer) {
      r.attempt++;
    }
    setState(accountId, next);
    _scheduleProcess(accountId);
  }

  void processAllAccounts() {
    if (_disposed) return;
    for (final id in accountIds()) {
      processAccountState(id);
    }
  }

  void processAccountState(String accountId) {
    if (_disposed || !isEnabled(accountId)) return;
    final r = runtime(accountId);

    if (!_networkAvailable) {
      if (r.state == AccountConnectionState.online ||
          r.state == AccountConnectionState.connecting ||
          attemptReconnect(r.state)) {
        if (r.state != AccountConnectionState.noInternet) {
          _cancelDue(r);
          setState(accountId, AccountConnectionState.noInternet);
        }
      }
      return;
    }

    if (r.state == AccountConnectionState.noInternet) {
      r.attempt = 0;
      r.connectStartedAt = null;
      setState(accountId, AccountConnectionState.offline);
    }

    final current = r.state;
    if (current == AccountConnectionState.online) {
      unawaited(_processOnline(accountId, r));
      return;
    }

    if (current == AccountConnectionState.connecting) {
      final started = r.connectStartedAt;
      final elapsed = started == null
          ? Duration.zero
          : now().difference(started);
      final remaining = connectTimeout - elapsed;
      if (remaining <= Duration.zero) {
        unawaited(_timeoutConnect(accountId, r));
      } else {
        _armDue(accountId, remaining);
      }
      return;
    }

    if (!attemptReconnect(current)) return;

    if (reconnectImmediately(current)) {
      // Conversations reconnects an OFFLINE account without waiting; the
      // aggressive flag only affects the backoff states below. Calling
      // _tryConnect directly (not arming another zero-delay timer) matters:
      // a zero timer that re-enters this branch would spin forever.
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
    if (_disposed ||
        !isEnabled(accountId) ||
        r.state != AccountConnectionState.online ||
        r.lossInProgress) {
      return;
    }

    final generation = r.generation;
    final n = now();
    if (pingTimedOut(
      now: n,
      lastPacketReceived: r.lastPacketReceived,
      lastPingSent: r.lastPingSent,
    )) {
      if (r.lossInProgress) return;
      r.lossInProgress = true;
      _log.warning('account $accountId ping timeout; forcing reconnect');
      r.generation++;
      r.pingInFlight = false;
      _cancelDue(r);
      await _safeDisconnect(accountId);
      if (_disposed || !isEnabled(accountId)) return;
      if (r.generation != generation + 1 ||
          r.state != AccountConnectionState.online) {
        r.lossInProgress = false;
        return;
      }
      r.lossInProgress = false;
      onConnectionLost(
        accountId,
        AccountConnectionState.offline,
        incrementAttempt: true,
      );
      return;
    }

    final interval = foreground ? pingMinInterval : pingMaxInterval;
    if (!r.pingNow &&
        !pingIsDue(
          now: n,
          lastPacketReceived: r.lastPacketReceived,
          lastPingSent: r.lastPingSent,
          interval: interval,
        )) {
      // Arm wake for the remaining idle window (Conversations
      // scheduleWakeUpCall).
      final last = r.lastPacketReceived ?? r.lastPingSent ?? n;
      final remaining = interval - n.difference(last);
      if (remaining > Duration.zero) {
        _armDue(accountId, remaining);
      }
      return;
    }
    if (r.pingInFlight) {
      // A ping is already out. Keep a wake at its deadline; the result path and
      // the timeout path both guard on [generation].
      final sent = r.lastPingSent;
      if (sent != null) {
        final remaining = pingTimeout - n.difference(sent);
        if (remaining > Duration.zero) _armDue(accountId, remaining);
      }
      return;
    }

    r.pingNow = false;
    r.pingInFlight = true;
    r.lastPingSent = n;
    // Wake before pingTimeout so a dead socket is noticed under Doze.
    _armDue(accountId, pingTimeout);
    var ok = false;
    try {
      ok = await sendPing(accountId);
    } catch (e, st) {
      _log.warning('account $accountId ping failed: $e', e, st);
    }
    if (_disposed ||
        !isEnabled(accountId) ||
        r.generation != generation ||
        r.state != AccountConnectionState.online) {
      return;
    }
    r.pingInFlight = false;
    if (!ok) {
      if (r.lossInProgress) return;
      r.lossInProgress = true;
      _cancelDue(r);
      await _safeDisconnect(accountId);
      if (_disposed ||
          !isEnabled(accountId) ||
          r.generation != generation ||
          r.state != AccountConnectionState.online) {
        r.lossInProgress = false;
        return;
      }
      r.lossInProgress = false;
      onConnectionLost(
        accountId,
        AccountConnectionState.offline,
        incrementAttempt: true,
      );
    } else {
      notifyPacketReceived(accountId);
    }
  }

  Future<void> _timeoutConnect(
    String accountId,
    AccountConnectionRuntime r,
  ) async {
    if (_disposed ||
        !isEnabled(accountId) ||
        r.state != AccountConnectionState.connecting ||
        r.connectTimeoutInFlight) {
      return;
    }
    final started = r.connectStartedAt;
    if (started != null && now().difference(started) < connectTimeout) {
      return;
    }
    r.connectTimeoutInFlight = true;
    r.generation++;
    r.pingInFlight = false;
    _cancelDue(r);
    try {
      await _safeDisconnect(accountId);
      if (_disposed || !isEnabled(accountId)) return;
      if (r.state != AccountConnectionState.connecting) return;
      // Conversations `triggerConnectionTimeout`: reset the connection clock so
      // getTimeToNextAttempt does not subtract the entire 90 s timeout (or the
      // teardown above) and reconnect in a tight loop.
      r.connectStartedAt = now();
      _log.warning('account $accountId CONNECT_TIMEOUT');
      onConnectionLost(
        accountId,
        AccountConnectionState.connectionTimeout,
        incrementAttempt: true,
      );
    } finally {
      r.connectTimeoutInFlight = false;
    }
  }

  Future<void> _tryConnect(String accountId, AccountConnectionRuntime r) async {
    if (_disposed || !isEnabled(accountId)) return;
    if (r.connectInFlight || r.state == AccountConnectionState.connecting) {
      return;
    }
    if (!_networkAvailable) {
      if (r.state != AccountConnectionState.noInternet) {
        _cancelDue(r);
        setState(accountId, AccountConnectionState.noInternet);
      }
      return;
    }

    _cancelDue(r);
    final generation = ++r.generation;
    r.connectInFlight = true;
    r.connectTimeoutInFlight = false;
    r.lossInProgress = false;
    setState(accountId, AccountConnectionState.connecting);
    _armDue(accountId, connectTimeout);

    var ok = false;
    try {
      ok = await connectAccount(accountId);
    } catch (e, st) {
      _log.warning('account $accountId connect threw: $e', e, st);
    }
    if (_disposed) {
      r.connectInFlight = false;
      return;
    }

    final stale =
        !isEnabled(accountId) ||
        !identical(_runtimes[accountId], r) ||
        generation != r.generation ||
        r.state != AccountConnectionState.connecting;
    if (stale) {
      // The attempt was superseded (timeout, user retry, network loss,
      // removal). If it somehow produced a live socket, close it before
      // releasing the mutex — no newer attempt can start while we hold it.
      if (ok) await _safeDisconnect(accountId);
      r.connectInFlight = false;
      if (!_disposed &&
          isEnabled(accountId) &&
          identical(_runtimes[accountId], r)) {
        _scheduleProcess(accountId);
      }
      return;
    }

    r.connectInFlight = false;
    if (ok) {
      setState(accountId, AccountConnectionState.online);
      return;
    }
    // [XmppService.connect] has its own 90 s ceiling. If it returned a generic
    // timeout just before the controller's timer fired, treat it as
    // CONNECT_TIMEOUT (and reset the clock) instead of UNREACHABLE followed by
    // an immediate retry because the attempt already lasted the full interval.
    final started = r.connectStartedAt;
    if (started != null && now().difference(started) >= connectTimeout) {
      r.connectStartedAt = now();
      onConnectionLost(accountId, AccountConnectionState.connectionTimeout);
      return;
    }
    final failure =
        connectFailureState?.call(accountId) ??
        AccountConnectionState.unreachable;
    onConnectionLost(accountId, failure);
  }

  Future<void> _safeDisconnect(String accountId) async {
    try {
      await disconnectAccount(accountId).timeout(disconnectTimeout);
    } catch (e, st) {
      _log.fine('account $accountId disconnect failed: $e', e, st);
    }
  }

  /// User-initiated "try again" / cold start: force offline then process.
  void requestConnect(String accountId) {
    if (_disposed) return;
    final r = runtime(accountId);
    r.generation++;
    r.attempt = 0;
    r.connectStartedAt = null;
    r.pingInFlight = false;
    r.pingNow = false;
    r.lossInProgress = false;
    r.connectTimeoutInFlight = false;
    r.lastPingSent = null;
    _cancelDue(r);
    setState(accountId, AccountConnectionState.offline);
    if (r.connectInFlight) {
      // Do not leave a retry waiting on a socket that is already being
      // replaced. The old future stays the mutex holder; this just unblocks it.
      unawaited(_safeDisconnect(accountId));
    }
    _scheduleProcess(accountId);
  }
}
