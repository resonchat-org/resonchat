// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Home after login: stacked chat list on phones; FluffyChat-style two-column
// master/detail on wide windows (no go_router required).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';
import '../chat/chat_page.dart';
import '../chats/chats_page.dart';
import '../column_mode.dart';
import '../empty_chat_pane.dart';
import '../two_column_layout.dart';

/// Route `/chats`: list alone, or list + conversation when [isColumnMode].
class HomeShell extends ConsumerWidget {
  const HomeShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wide = isColumnMode(context);
    final selected = ref.watch(selectedChatKeyProvider);

    if (!wide) {
      return const ChatsPage();
    }

    return Scaffold(
      body: TwoColumnLayout(
        mainView: ChatsPage(activeChatKey: selected),
        sideView: selected == null || selected.isEmpty
            ? const EmptyChatPane()
            : ChatPage(
                key: ValueKey(selected),
                chatJid: selected,
                embedded: true,
              ),
      ),
    );
  }
}
