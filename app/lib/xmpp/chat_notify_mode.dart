// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Per-conversation notification mode (Conversations conference notify dialog).
//
// Groups have three states; 1:1 only uses [all] and [never]. A silenced group
// may also list people who still notify ("Still notify").

import 'dart:convert';

/// How loudly a conversation may interrupt the user.
enum ChatNotifyMode {
  /// Every inbound message may alert.
  all,

  /// Groups only: alert on nick highlight / MUC PM (Conversations
  /// `notify_only_when_highlighted`).
  highlights,

  /// Never alert, even when highlighted (Conversations `notify_never`).
  never,
}

/// Storage bits for [ChatNotifyMode] (`chats.muted` + `chats.always_notify`).
typedef ChatNotifyFlags = ({bool muted, bool alwaysNotify});

extension ChatNotifyModeX on ChatNotifyMode {
  /// Flags to write when the user picks this mode.
  ChatNotifyFlags get storageFlags => switch (this) {
    ChatNotifyMode.never => (muted: true, alwaysNotify: true),
    ChatNotifyMode.highlights => (muted: false, alwaysNotify: false),
    ChatNotifyMode.all => (muted: false, alwaysNotify: true),
  };

  /// True when the list should show a "muted" affordance (not [all]).
  bool get isSilenced => this != ChatNotifyMode.all;
}

/// Reads the mode from stored flags.
ChatNotifyMode chatNotifyModeOf({
  required bool muted,
  required bool alwaysNotify,
}) {
  if (muted) return ChatNotifyMode.never;
  if (!alwaysNotify) return ChatNotifyMode.highlights;
  return ChatNotifyMode.all;
}

/// Stored key for one room member: bare JID when we know it, otherwise nick.
String notifyExceptKey({String? realJid, required String nick}) {
  final jid = realJid?.trim().toLowerCase() ?? '';
  if (jid.contains('@')) return jid;
  return 'nick:${nick.trim()}';
}

/// True when [nick] or [realJid] is in the Still notify list.
bool senderIsNotifyExcept({
  required Iterable<String> except,
  required String nick,
  String? realJid,
}) {
  if (except.isEmpty) return false;
  final keys = except is Set<String> ? except : except.toSet();
  final jid = realJid?.trim().toLowerCase() ?? '';
  if (jid.isNotEmpty && keys.contains(jid)) return true;
  final name = nick.trim();
  if (name.isNotEmpty && keys.contains('nick:$name')) return true;
  return false;
}

/// JSON array stored on `chats.notify_except`.
List<String> decodeNotifyExcept(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return const [];
  try {
    final decoded = jsonDecode(trimmed);
    if (decoded is! List) return const [];
    return [
      for (final item in decoded)
        if (item is String && item.isNotEmpty) item,
    ];
  } on FormatException {
    return const [];
  }
}

String encodeNotifyExcept(Iterable<String> keys) => jsonEncode(keys.toList());
