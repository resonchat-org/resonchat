// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Android process keepalive (lives under lib/platform/, same as other
// MethodChannel / OS-specific Dart): foreground service, battery-optimization
// prompt, and AlarmManager wakeups (Conversations scheduleWakeUpCall).
// Desktop builds no-op — connection liveness is separate (IQ ping).

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:logging/logging.dart';

import 'package:resonchat/xmpp/account_connection_controller.dart';

const _channelName = 'org.resonchat.resonchat/keepalive';

/// AlarmManager-backed [ConnectionWakeScheduler] (Conversations scheduleWakeUpCall).
class AndroidWakeScheduler implements ConnectionWakeScheduler {
  @override
  void setOnWake(void Function(int requestCode)? callback) {
    AndroidKeepAlive.ensureWakeHandler();
    AndroidKeepAlive.onWake = callback;
  }

  @override
  Future<void> schedule(Duration delay, int requestCode) =>
      AndroidKeepAlive.scheduleWake(delay, requestCode);

  @override
  Future<void> cancel(int requestCode) =>
      AndroidKeepAlive.cancelWake(requestCode);
}

/// Starts / stops the Android foreground service that keeps the process alive
/// while enabled accounts exist, and schedules Doze-safe wakeups for reconnect.
class AndroidKeepAlive {
  AndroidKeepAlive._();

  static final _log = Logger('AndroidKeepAlive');
  static const _channel = MethodChannel(_channelName);
  static bool _handlerInstalled = false;
  static void Function(int requestCode)? onWake;

  static bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// True when this platform should run a process keepalive / AlarmManager.
  static bool get isSupported => _supported;

  /// Installs the native → Dart wake callback once.
  static void ensureWakeHandler() {
    if (!_supported || _handlerInstalled) return;
    _handlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onWake') {
        final code = call.arguments is Map
            ? (call.arguments as Map)['requestCode'] as int? ?? 0
            : 0;
        onWake?.call(code);
      }
    });
  }

  static Future<void> start({
    String? notificationTitle,
    String? notificationText,
  }) async {
    if (!_supported) return;
    ensureWakeHandler();
    try {
      await _channel.invokeMethod<void>('start', {
        'title': notificationTitle ?? 'ResonChat',
        'text': notificationText ?? 'Connected',
      });
    } catch (e, st) {
      _log.warning('keepalive start failed: $e', e, st);
    }
  }

  static Future<void> stop() async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (e, st) {
      _log.warning('keepalive stop failed: $e', e, st);
    }
  }

  /// Conversations [scheduleWakeUpCall]: wake after [delay] for [requestCode].
  static Future<void> scheduleWake(Duration delay, int requestCode) async {
    if (!_supported) return;
    ensureWakeHandler();
    try {
      await _channel.invokeMethod<void>('scheduleWake', {
        'millis': delay.inMilliseconds.clamp(1, 24 * 60 * 60 * 1000),
        'requestCode': requestCode,
      });
    } catch (e, st) {
      _log.fine('scheduleWake failed: $e', e, st);
    }
  }

  static Future<void> cancelWake(int requestCode) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>('cancelWake', {
        'requestCode': requestCode,
      });
    } catch (e, st) {
      _log.fine('cancelWake failed: $e', e, st);
    }
  }

  /// Opens the system dialog to ignore battery optimizations when not already
  /// exempt. No-op on desktop / when already ignoring.
  static Future<bool> requestIgnoreBatteryOptimizations() async {
    if (!_supported) return false;
    try {
      final result = await _channel.invokeMethod<bool>(
        'requestIgnoreBatteryOptimizations',
      );
      return result ?? false;
    } catch (e, st) {
      _log.warning('battery opt request failed: $e', e, st);
      return false;
    }
  }

  static Future<bool> isIgnoringBatteryOptimizations() async {
    if (!_supported) return true;
    try {
      final result = await _channel.invokeMethod<bool>(
        'isIgnoringBatteryOptimizations',
      );
      return result ?? false;
    } catch (e, st) {
      _log.warning('battery opt check failed: $e', e, st);
      return false;
    }
  }
}

/// Convenience used by settings / tests that must not import `dart:io` on web.
bool get androidKeepAlivePlatform {
  if (kIsWeb) return false;
  try {
    return Platform.isAndroid;
  } catch (_) {
    return false;
  }
}
