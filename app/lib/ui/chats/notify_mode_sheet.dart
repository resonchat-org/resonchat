// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Per-conversation notification mode picker (Conversations conference notify).

import 'package:flutter/material.dart';

import '../../account/resolve.dart';
import '../../l10n/l10n.dart';
import '../../store/database.dart';

/// Icon for the current [ChatNotifyMode] (list row / settings tile).
IconData notifyModeIcon(ChatNotifyMode mode) => switch (mode) {
  ChatNotifyMode.never => Icons.notifications_off,
  ChatNotifyMode.highlights => Icons.notifications_paused,
  ChatNotifyMode.all => Icons.notifications_none,
};

/// Localized label for [mode].
String notifyModeLabel(AppLocalizations l10n, ChatNotifyMode mode) =>
    switch (mode) {
      ChatNotifyMode.all => l10n.notifyAllMessages,
      ChatNotifyMode.highlights => l10n.notifyOnlyWhenHighlighted,
      ChatNotifyMode.never => l10n.notifyNever,
    };

/// Conversations-style sheet: all / highlighted / never for groups.
Future<void> pickChatNotifyMode(
  BuildContext context, {
  required AppDatabase db,
  required Chat chat,
}) async {
  final l10n = context.l10n;
  final current = chatNotifyModeOf(
    muted: chat.muted,
    alwaysNotify: chat.alwaysNotify,
  );
  final modes = chat.isGroup
      ? ChatNotifyMode.values
      : const [ChatNotifyMode.all, ChatNotifyMode.never];
  final picked = await showModalBottomSheet<ChatNotifyMode>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(title: Text(l10n.notificationSettings)),
          for (final mode in modes)
            ListTile(
              leading: Icon(notifyModeIcon(mode)),
              title: Text(notifyModeLabel(l10n, mode)),
              trailing: mode == current ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(ctx, mode),
            ),
        ],
      ),
    ),
  );
  if (picked == null) return;
  await db.setChatNotifyMode(chat.jid, picked);
}

/// Opens notification settings for [chatKey] (group sheet or 1:1 mute sheet).
Future<void> openChatNotifySettings(
  BuildContext context,
  String chatKey,
) async {
  final resolved = resolveChatKey(chatKey);
  final db = resolved.session.db;
  final chat = await db.getChat(resolved.jid);
  if (chat == null || !context.mounted) return;
  await pickChatNotifyMode(context, db: db, chat: chat);
}
