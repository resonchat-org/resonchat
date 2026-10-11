// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Home after login: Telegram-style Chats / Contacts / Me via
// [MainTabsLayout] (Telegram `MainTabsLayout` + `GlassTabView`).
// Wide windows keep FluffyChat-style master/detail for the Chats tab only.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/providers.dart';
import '../chat/chat_page.dart';
import '../chats/chats_page.dart';
import '../column_mode.dart';
import '../contacts/contacts_page.dart';
import '../empty_chat_pane.dart';
import '../me/me_page.dart';
import '../two_column_layout.dart';
import 'main_tabs_layout.dart';

/// Route `/chats`: [MainTabsLayout] shell.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final wide = isColumnMode(context);
    final selected = ref.watch(selectedChatKeyProvider);
    final media = MediaQuery.of(context);
    // DialogsActivity.MAIN_TABS_MARGIN = 8 above the system inset.
    final bottomGap = media.padding.bottom + kMainTabsMargin;

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

    final paddedMedia = media.copyWith(
      padding: media.padding.copyWith(
        bottom: media.padding.bottom + MainTabsLayout.contentInset,
      ),
      viewPadding: media.viewPadding.copyWith(
        bottom: media.viewPadding.bottom + MainTabsLayout.contentInset,
      ),
    );

    return Scaffold(
      extendBody: true,
      body: Stack(
        children: [
          Positioned.fill(
            child: MediaQuery(
              data: paddedMedia,
              child: IndexedStack(
                index: _tab,
                children: [chatsBody, const ContactsPage(), const MePage()],
              ),
            ),
          ),
          Positioned(
            left: kMainTabsMargin,
            right: kMainTabsMargin,
            bottom: bottomGap,
            child: MainTabsLayout(
              selectedIndex: _tab,
              onSelected: (i) => setState(() => _tab = i),
              tabs: [
                GlassTab(
                  icon: Icons.chat_bubble_outline,
                  selectedIcon: Icons.chat_bubble,
                  label: l10n.tabChats,
                ),
                GlassTab(
                  icon: Icons.people_outline,
                  selectedIcon: Icons.people,
                  label: l10n.tabContacts,
                ),
                GlassTab(
                  icon: Icons.person_outline,
                  selectedIcon: Icons.person,
                  label: l10n.tabMe,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
