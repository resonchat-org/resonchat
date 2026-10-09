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
final class AppNotifications {
  AppNotifications._();

  static final AppNotifications instance = AppNotifications._();

  static const _channelId = 'messages';
  static const _channelName = 'Messages';
  static const _channelDescription = 'Incoming chat messages';

  final _log = Logger('AppNotifications');
  final _plugin = FlutterLocalNotificationsPlugin();

  bool _ready = false;
  Future<void>? _init;

  /// Called when the user taps a shade entry. Payload is a [ChatRef.key].
  void Function(String chatKey)? onOpenChat;

  /// Idempotent init + Android 13+ permission request.
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
    const settings = InitializationSettings(android: android, linux: linux);

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
      await androidPlugin?.requestNotificationsPermission();
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
