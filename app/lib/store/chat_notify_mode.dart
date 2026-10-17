// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Per-conversation notification mode (Conversations conference notify dialog).
//
// Groups have three states; 1:1 only uses [all] and [never].

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
