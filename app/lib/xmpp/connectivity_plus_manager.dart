// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
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

  Future<void> start() async {
    if (_listening) return;
    _listening = true;
    var hadConnection = await hasConnection();
    _sub = _connectivity.onConnectivityChanged.listen((results) {
      final online = _isOnline(results);
      if (online) {
        _resolveWaiters();
        if (!hadConnection && !_becameOnline.isClosed) {
          _becameOnline.add(null);
        }
      }
      hadConnection = online;
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
  }

  @override
  Future<bool> hasConnection() async {
    try {
      final results = await _connectivity.checkConnectivity();
      return _isOnline(results);
    } catch (e) {
      _log.warning('connectivity check failed: $e');
      // Fail open so a plugin glitch does not brick login.
      return true;
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
}
