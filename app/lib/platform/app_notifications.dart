// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:logging/logging.dart';

import '../account/chat_ref.dart';
import '../xmpp/notify_policy.dart';

/// Posts [NotifyRequest]s into the system shade.
///
/// Policy stays in [notificationFor] / [decide]; this class is the mechanism
/// only. A null preview becomes [kNoPreviewText] so the shade never shows an
/// empty body line.
///
/// Android 13+ [POST_NOTIFICATIONS] is requested only on the first [post],
/// never at cold start.
final class AppNotifications {
  AppNotifications._();

  static final AppNotifications instance = AppNotifications._();

  static const _channelId = 'messages';
  static const _channelName = 'Messages';
  static const _channelDescription = 'Incoming chat messages';

  /// Toast activator GUID for unpackaged Windows builds (stable; do not rotate).
  static const _windowsNotificationGuid =
      '8f3a2c1e-6b4d-4a9f-b7e2-1c5d8a0f3e6b';

  final _log = Logger('AppNotifications');
  final _plugin = FlutterLocalNotificationsPlugin();

  bool _ready = false;
  Future<void>? _init;
  Future<void>? _permission;

  /// Called when the user taps a shade entry. Payload is a [ChatRef.key].
  void Function(String chatKey)? onOpenChat;

  /// Idempotent plugin init (channel create). Does **not** prompt for
  /// notification permission — see [_ensurePermission].
  Future<void> ensureReady() {
    return _init ??= _doInit();
  }

  Future<void> _doInit() async {
    if (kIsWeb) {
      _ready = true;
      return;
    }

    const android = AndroidInitializationSettings('@drawable/ic_stat_message');
    const linux = LinuxInitializationSettings(defaultActionName: 'Open');
    // Required on Windows or initialize() throws and we stay !_ready.
    const windows = WindowsInitializationSettings(
      appName: 'resonchat',
      appUserModelId: 'Org.Resonchat.Resonchat',
      guid: _windowsNotificationGuid,
    );
    const settings = InitializationSettings(
      android: android,
      linux: linux,
      windows: windows,
    );

    try {
      await _plugin.initialize(
        settings,
        onDidReceiveNotificationResponse: _onSelect,
      );
    } catch (e, st) {
      _log.warning('notification plugin init failed: $e', e, st);
      _ready = false;
      return;
    }

    if (defaultTargetPlatform == TargetPlatform.android) {
      final androidPlugin = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      await androidPlugin?.createNotificationChannel(
        const AndroidNotificationChannel(
          _channelId,
          _channelName,
          description: _channelDescription,
          importance: Importance.high,
        ),
      );
    }

    _ready = true;
  }

  /// Android 13+ runtime prompt, once, when we actually need the shade.
  Future<void> _ensurePermission() {
    return _permission ??= _doRequestPermission();
  }

  Future<void> _doRequestPermission() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    final androidPlugin = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    try {
      await androidPlugin?.requestNotificationsPermission();
    } catch (e, st) {
      _log.fine('notification permission request failed: $e', e, st);
    }
  }

  void _onSelect(NotificationResponse response) {
    final payload = response.payload;
    if (payload == null || payload.isEmpty) return;
    onOpenChat?.call(payload);
  }

  /// Payload of the notification that cold-started the process, if any.
  Future<String?> launchChatKey() async {
    await ensureReady();
    if (!_ready) return null;
    try {
      final details = await _plugin.getNotificationAppLaunchDetails();
      if (details?.didNotificationLaunchApp != true) return null;
      final payload = details!.notificationResponse?.payload;
      if (payload == null || payload.isEmpty) return null;
      return payload;
    } catch (e, st) {
      _log.fine('launch details failed: $e', e, st);
      return null;
    }
  }

  /// Show (or replace) the shade entry for one conversation.
  Future<void> post({
    required String accountId,
    required String chatJid,
    required String title,
    required NotifyRequest request,
  }) async {
    await ensureReady();
    if (!_ready) return;
    await _ensurePermission();

    final chatKey = ChatRef(accountId: accountId, jid: chatJid).key;
    final body = request.preview ?? kNoPreviewText;
    final id = _idFor(chatKey);
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: _channelDescription,
        importance: request.decision.banner ? Importance.high : Importance.low,
        priority: request.decision.banner ? Priority.high : Priority.low,
        playSound: request.decision.sound,
        enableVibration: request.decision.sound,
        category: AndroidNotificationCategory.message,
        styleInformation: BigTextStyleInformation(body),
      ),
      linux: LinuxNotificationDetails(suppressSound: !request.decision.sound),
      windows: WindowsNotificationDetails(
        audio: request.decision.sound
            ? null
            : WindowsNotificationAudio.silent(),
        duration: request.decision.banner
            ? WindowsNotificationDuration.long
            : WindowsNotificationDuration.short,
      ),
    );

    try {
      await _plugin.show(id, title, body, details, payload: chatKey);
    } catch (e, st) {
      _log.fine('show failed: $e', e, st);
    }
  }

  /// Clear the shade entry when the user opens the conversation.
  Future<void> cancelChat({
    required String accountId,
    required String chatJid,
  }) async {
    if (!_ready && _init == null) return;
    await ensureReady();
    if (!_ready) return;
    final chatKey = ChatRef(accountId: accountId, jid: chatJid).key;
    try {
      await _plugin.cancel(_idFor(chatKey));
    } catch (e, st) {
      _log.fine('cancel failed: $e', e, st);
    }
  }

  /// Stable positive id so successive messages in one chat replace each other.
  static int _idFor(String chatKey) => chatKey.hashCode & 0x7fffffff;
}
