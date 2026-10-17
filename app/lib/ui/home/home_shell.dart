// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Home after login: Chats / Contacts / Me.
//
// Portrait and landscape do not share a layout. Portrait is [PortraitHome]
// (floating dock, full-screen routes). Landscape is only the tab body here;
// [LandscapeFrame] wraps the root navigator so the rail stays outside every
// pushed page. Wide windows keep master/detail on the Chats tab either way.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';
import '../chat/chat_page.dart';
import '../chats/chats_page.dart';
import '../column_mode.dart';
import '../contacts/contacts_page.dart';
import '../empty_chat_pane.dart';
import '../me/me_page.dart';
import '../two_column_layout.dart';
import 'portrait_home.dart';

/// Route `/chats`.
class HomeShell extends ConsumerWidget {
  const HomeShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wide = isColumnMode(context);
    final selected = ref.watch(selectedChatKeyProvider);
    final tab = ref.watch(homeTabIndexProvider);
    final landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;

    final chatsBody = wide
        ? TwoColumnLayout(
            mainView: ChatsPage(activeChatKey: selected),
            sideView: selected == null || selected.isEmpty
                ? const EmptyChatPane()
                : ChatPage(
                    key: ValueKey(selected),
                    chatJid: selected,
                    embedded: true,
                  ),
          )
        : const ChatsPage();
    final pages = [chatsBody, const ContactsPage(), const MePage()];

    if (landscape) {
      return IndexedStack(index: tab, children: pages);
    }
    return PortraitHome(
      tab: tab,
      pages: pages,
      onSelect: (index) {
        ref.read(homeTabIndexProvider.notifier).state = index;
      },
    );
  }
}
