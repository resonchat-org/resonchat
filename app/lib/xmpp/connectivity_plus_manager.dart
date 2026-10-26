// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Real network-availability checks for moxxmpp (replaces AlwaysConnected).

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:logging/logging.dart';
import 'package:moxxmpp/moxxmpp.dart';

/// [ConnectivityManager] backed by `connectivity_plus`.
class ConnectivityPlusConnectivityManager extends ConnectivityManager {
  ConnectivityPlusConnectivityManager({Connectivity? connectivity})
    : _connectivity = connectivity ?? Connectivity();

  final Connectivity _connectivity;
  final _log = Logger('ConnectivityPlusConnectivityManager');
  final List<Completer<void>> _waiters = [];
  StreamSubscription<List<ConnectivityResult>>? _sub;
  bool _listening = false;

  /// Fired when connectivity flips from none → some interface.
  final StreamController<void> _becameOnline =
      StreamController<void>.broadcast();
  Stream<void> get becameOnline => _becameOnline.stream;

  /// Fired when connectivity flips from some interface → none.
  final StreamController<void> _becameOffline =
      StreamController<void>.broadcast();
  Stream<void> get becameOffline => _becameOffline.stream;

  /// Fired when the interface changes while staying online (Wi-Fi → cellular).
  /// Conversations pings on every CONNECTIVITY_ACTION for this reason.
  final StreamController<void> _networkChanges =
      StreamController<void>.broadcast();
  Stream<void> get networkChanges => _networkChanges.stream;

  bool _online = true;

  /// Fingerprint of the last online [ConnectivityResult] set. Used so
  /// [networkChanges] only fires when the interface set actually changes —
  /// connectivity_plus often re-emits the same Wi-Fi list, and treating each
  /// echo as CONNECTIVITY_ACTION would reset backoff / schedule pings for no
  /// reason (Conversations only acts on real network transitions).
  String? _onlineFingerprint;

  /// Last state observed by the change listener (false before [start] only if
  /// the initial check found no interface).
  bool get isOnline => _online;

  Future<void> start() async {
    if (_listening) return;
    _listening = true;
    List<ConnectivityResult> initial;
    try {
      initial = await _connectivity.checkConnectivity();
    } catch (_) {
      initial = const <ConnectivityResult>[ConnectivityResult.none];
    }
    var hadConnection = _isOnline(initial);
    _online = hadConnection;
    _onlineFingerprint = hadConnection ? _fingerprint(initial) : null;
    _sub = _connectivity.onConnectivityChanged.listen((results) {
      final online = _isOnline(results);
      if (online) {
        _resolveWaiters();
        final fingerprint = _fingerprint(results);
        if (!hadConnection && !_becameOnline.isClosed) {
          _becameOnline.add(null);
          _onlineFingerprint = fingerprint;
        } else if (hadConnection &&
            fingerprint != _onlineFingerprint &&
            !_networkChanges.isClosed) {
          // Interface set changed while staying online (Wi-Fi → cellular,
          // VPN up/down). Existing sockets are not guaranteed to survive it.
          _onlineFingerprint = fingerprint;
          _networkChanges.add(null);
        }
      } else if (hadConnection && !_becameOffline.isClosed) {
        _onlineFingerprint = null;
        _becameOffline.add(null);
      }
      hadConnection = online;
      _online = online;
    });
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    _listening = false;
    for (final c in _waiters) {
      if (!c.isCompleted) c.complete();
    }
    _waiters.clear();
  }

  void dispose() {
    unawaited(stop());
    unawaited(_becameOnline.close());
    unawaited(_becameOffline.close());
    unawaited(_networkChanges.close());
  }

  @override
  Future<bool> hasConnection() async => hasConnectionStrict(failOpen: true);

  /// Like [hasConnection], but [failOpen] controls the plugin-error path.
  ///
  /// Login waiters use [failOpen] true so a broken plugin cannot brick sign-in.
  /// The reconnect clock's offline recheck must use false — otherwise a probe
  /// error every 15 s would look like "network restored" and spam connects.
  Future<bool> hasConnectionStrict({bool failOpen = true}) async {
    try {
      final results = await _connectivity.checkConnectivity();
      return _isOnline(results);
    } catch (e) {
      _log.warning('connectivity check failed: $e');
      return failOpen;
    }
  }

  @override
  Future<void> waitForConnection() async {
    if (await hasConnection()) return;
    final completer = Completer<void>();
    _waiters.add(completer);
    return completer.future;
  }

  void _resolveWaiters() {
    for (final c in _waiters) {
      if (!c.isCompleted) c.complete();
    }
    _waiters.clear();
  }

  static bool _isOnline(List<ConnectivityResult> results) {
    if (results.isEmpty) return false;
    return results.any((r) => r != ConnectivityResult.none);
  }

  /// Stable key for a result set (order-independent).
  static String _fingerprint(List<ConnectivityResult> results) {
    final names = [
      for (final r in results)
        if (r != ConnectivityResult.none) r.name,
    ]..sort();
    return names.join('|');
  }
}
