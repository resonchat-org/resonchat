// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Home after login: Chats / Contacts / Me.
//
// The two layouts do not share navigation chrome. Narrow windows are
// [PortraitHome] (floating dock, full-screen routes). From
// [kNavigationRailMinWidth] up, this widget is only the tab body with
// master/detail on Chats; [LandscapeFrame] wraps the root navigator so the
// rail stays outside every pushed page.

import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:resonchat/state/providers.dart';
import 'package:resonchat/ui/chat/chat_page.dart';
import 'package:resonchat/ui/chats/chats_page.dart';
import 'package:resonchat/ui/column_mode.dart';
import 'package:resonchat/ui/contacts/contacts_page.dart';
import 'package:resonchat/ui/empty_chat_pane.dart';
import 'package:resonchat/ui/home/portrait_home.dart';
import 'package:resonchat/ui/home/shell_actions.dart';
import 'package:resonchat/ui/me/me_page.dart';
import 'package:resonchat/ui/two_column_layout.dart';

/// Route `/chats`.
class HomeShell extends ConsumerWidget {
  const HomeShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wide = isColumnMode(context);
    final selected = ref.watch(selectedChatKeyProvider);
    final tab = ref.watch(homeTabIndexProvider);
    remindPendingRequests(context, ref);

    // Same ≥600 gate as the side rail: no 600–720 transition band.
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

    if (wide) {
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
