// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Home after login: Telegram-style Chats / Contacts / Me.
// Portrait uses [MainTabsLayout] (floating glass capsule); landscape uses a
// normal [NavigationRail] on the left. Wide windows keep FluffyChat-style
// master/detail for the Chats tab only.

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
import '../theme.dart';
import '../two_column_layout.dart';
import 'main_tabs_layout.dart';

/// Route `/chats`: main-tab shell.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  void _selectTab(int i) {
    ref.read(homeTabIndexProvider.notifier).state = i;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final wide = isColumnMode(context);
    final selected = ref.watch(selectedChatKeyProvider);
    final tab = ref.watch(homeTabIndexProvider);
    final media = MediaQuery.of(context);
    final landscape = media.orientation == Orientation.landscape;

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
      final tg = context.tg;
      return Scaffold(
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: tab,
              onDestinationSelected: _selectTab,
              labelType: NavigationRailLabelType.all,
              backgroundColor: tg.pageBackground,
              // Match portrait MainTabsLayout: accent selected, textPrimary idle.
              indicatorColor: tg.accent.withValues(alpha: 0.09),
              selectedIconTheme: IconThemeData(color: tg.accent, size: 24),
              unselectedIconTheme: IconThemeData(
                color: tg.textPrimary,
                size: 24,
              ),
              selectedLabelTextStyle: TextStyle(
                color: tg.accent,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
              unselectedLabelTextStyle: TextStyle(
                color: tg.textPrimary,
                fontSize: 13,
              ),
              destinations: [
                NavigationRailDestination(
                  icon: const Icon(Icons.chat_bubble_outline),
                  selectedIcon: const Icon(Icons.chat_bubble),
                  label: Text(l10n.tabChats),
                ),
                NavigationRailDestination(
                  icon: const Icon(Icons.people_outline),
                  selectedIcon: const Icon(Icons.people),
                  label: Text(l10n.tabContacts),
                ),
                NavigationRailDestination(
                  icon: const Icon(Icons.person_outline),
                  selectedIcon: const Icon(Icons.person),
                  label: Text(l10n.tabMe),
                ),
              ],
            ),
            VerticalDivider(width: 1, thickness: 1, color: tg.separator),
            Expanded(
              child: IndexedStack(index: tab, children: pages),
            ),
          ],
        ),
      );
    }

    final bottomGap = media.padding.bottom + kMainTabsMarginBottom;
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
              child: IndexedStack(index: tab, children: pages),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: bottomGap,
            child: Center(
              child: MainTabsLayout(
                selectedIndex: tab,
                onSelected: _selectTab,
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
          ),
        ],
      ),
    );
  }
}
