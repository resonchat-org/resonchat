// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Single entry point for opening a conversation: push a route on phones,
// select the side pane on tablet/desktop (FluffyChat column mode).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';
import '../column_mode.dart';

/// Opens [chatKey] ([ChatRef.key] or legacy bare JID).
///
/// In column mode, updates [selectedChatKeyProvider] and pops back to the
/// home shell. Otherwise pushes `/chat`.
void openChat(BuildContext context, String chatKey) {
  if (chatKey.isEmpty) return;
  final nav = Navigator.of(context);
  if (isColumnMode(context)) {
    ProviderScope.containerOf(context)
            .read(selectedChatKeyProvider.notifier)
            .state =
        chatKey;
    if (nav.canPop()) {
      nav.popUntil((route) => route.settings.name == '/chats' || route.isFirst);
    }
    return;
  }
  nav.pushNamed('/chat', arguments: chatKey);
}

/// Clears the column-mode selection (embedded chat "close").
void clearSelectedChat(BuildContext context) {
  ProviderScope.containerOf(context)
          .read(selectedChatKeyProvider.notifier)
          .state =
      null;
}
