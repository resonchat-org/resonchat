// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Portrait home: tab body, with the floating dock over the bottom.
// Secondary pages are full-screen routes on the root navigator.

import 'package:flutter/material.dart';

import 'package:resonchat/l10n/l10n.dart';
import 'package:resonchat/ui/home/navigation_dock.dart';

class PortraitHome extends StatelessWidget {
  const PortraitHome({
    super.key,
    required this.tab,
    required this.pages,
    required this.onSelect,
  });

  final int tab;
  final List<Widget> pages;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final media = MediaQuery.of(context);
    final inset = NavigationDock.insetOf(context);
    final paddedMedia = media.copyWith(
      padding: media.padding.copyWith(bottom: inset),
      viewPadding: media.viewPadding.copyWith(bottom: inset),
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
            bottom: 0,
            child: NavigationDock(
              selectedIndex: tab,
              onSelected: onSelect,
              destinations: [
                NavigationDockDestination(
                  icon: Icons.chat_bubble,
                  label: l10n.tabChats,
                ),
                NavigationDockDestination(
                  icon: Icons.people,
                  label: l10n.tabContacts,
                ),
                NavigationDockDestination(
                  icon: Icons.person,
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
