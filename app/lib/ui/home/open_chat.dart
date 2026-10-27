// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Single entry point for opening a conversation: push a route on phones,
// select the side pane on tablet/desktop (FluffyChat column mode).

import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:resonchat/state/providers.dart';
import 'package:resonchat/ui/column_mode.dart';

/// Arguments for `/chat` — same shape in portrait and landscape.
class OpenChatArgs {
  const OpenChatArgs(this.chatKey, {this.focusMessageAnchor});

  final String chatKey;

  /// Scroll target ([unreadAnchorOf] / room stanza-id). Null = open at unread.
  final String? focusMessageAnchor;
}

/// Opens [chatKey] ([ChatRef.key] or legacy bare JID).
///
/// Portrait and landscape use the same API. Optional [focusMessageAnchor]
/// scrolls to that message after open (search hit, group forward origin, …).
///
/// Column mode updates [selectedChatKeyProvider] (+ focus provider) and pops
/// back to the home shell. Phone pushes `/chat`.
void openChat(
  BuildContext context,
  String chatKey, {
  String? focusMessageAnchor,
}) {
  if (chatKey.isEmpty) return;
  final nav = Navigator.of(context);
  final trimmed = focusMessageAnchor?.trim();
  final focus = (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  final args = OpenChatArgs(chatKey, focusMessageAnchor: focus);

  if (isColumnMode(context)) {
    final container = ProviderScope.containerOf(context);
    // Set focus before the key so the pane rebuild sees both together.
    container.read(selectedChatFocusAnchorProvider.notifier).state = focus;
    container.read(selectedChatKeyProvider.notifier).state = chatKey;
    // Side pane is only built on the Chats tab — leave Contacts/Me first.
    container.read(homeTabIndexProvider.notifier).state = 0;
    if (nav.canPop()) {
      nav.popUntil((route) => route.settings.name == '/chats' || route.isFirst);
    }
    return;
  }
  nav.pushNamed('/chat', arguments: args);
}

/// Clears the column-mode selection (embedded chat "close").
void clearSelectedChat(BuildContext context) {
  final container = ProviderScope.containerOf(context);
  container.read(selectedChatFocusAnchorProvider.notifier).state = null;
  container.read(selectedChatKeyProvider.notifier).state = null;
}
