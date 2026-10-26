// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Landscape chrome: a rail that sits *beside* the root navigator, so a
// pushed page replaces the tab body and leaves the rail in place.
//
// Column-mode nesting (tray + inset chat) lives in [TwoColumnLayout] only —
// no tinted canvas, outer gutter, or dual cards here.

import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:resonchat/l10n/l10n.dart';
import 'package:resonchat/state/providers.dart';
import 'package:resonchat/ui/desktop_surface.dart';
import 'package:resonchat/ui/home/shell_actions.dart';
import 'package:resonchat/ui/theme.dart';

/// Rail plus the navigator's current page.
class LandscapeFrame extends ConsumerWidget {
  const LandscapeFrame({
    super.key,
    required this.navigatorKey,
    required this.child,
  });

  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  void _selectTab(WidgetRef ref, int index) {
    navigatorKey.currentState?.popUntil(
      (route) => route.settings.name == '/chats' || route.isFirst,
    );
    ref.read(homeTabIndexProvider.notifier).state = index;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tg = context.tg;
    // Main content keeps a left-edge radius beside the rail. Same page
    // background as the rail so the corner crescents read cleanly.
    const contentRadius = BorderRadius.only(
      topLeft: Radius.circular(kDesktopContentRadius),
      bottomLeft: Radius.circular(kDesktopContentRadius),
    );
    return _ShellOverlay(
      child: ColoredBox(
        color: tg.pageBackground,
        child: Row(
          children: [
            LandscapeNavRail(
              navigatorKey: navigatorKey,
              onSelectTab: (index) => _selectTab(ref, index),
            ),
            Expanded(
              child: ClipRRect(borderRadius: contentRadius, child: child),
            ),
          ],
        ),
      ),
    );
  }
}

/// The rail is a sibling of the navigator, so it needs its own overlay for
/// tooltips. The entry is rebuilt whenever the frame's child changes.
class _ShellOverlay extends StatefulWidget {
  const _ShellOverlay({required this.child});

  final Widget child;

  @override
  State<_ShellOverlay> createState() => _ShellOverlayState();
}

class _ShellOverlayState extends State<_ShellOverlay> {
  late final OverlayEntry _entry = OverlayEntry(
    builder: (context) => widget.child,
  );

  @override
  void didUpdateWidget(covariant _ShellOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_entry.mounted) _entry.markNeedsBuild();
  }

  @override
  Widget build(BuildContext context) {
    return Overlay(initialEntries: [_entry]);
  }
}

class LandscapeNavRail extends ConsumerWidget {
  const LandscapeNavRail({
    super.key,
    required this.navigatorKey,
    required this.onSelectTab,
  });

  final GlobalKey<NavigatorState> navigatorKey;
  final ValueChanged<int> onSelectTab;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final tg = context.tg;
    final tab = ref.watch(homeTabIndexProvider);
    return NavigationRail(
      selectedIndex: tab,
      onDestinationSelected: onSelectTab,
      labelType: NavigationRailLabelType.all,
      backgroundColor: tg.pageBackground,
      indicatorColor: tg.accent.withValues(alpha: 0.09),
      selectedIconTheme: IconThemeData(color: tg.accent, size: 24),
      unselectedIconTheme: IconThemeData(color: tg.textPrimary, size: 24),
      selectedLabelTextStyle: TextStyle(
        color: tg.accent,
        fontSize: 13,
        fontWeight: FontWeight.w600,
      ),
      unselectedLabelTextStyle: TextStyle(color: tg.textPrimary, fontSize: 13),
      trailingAtBottom: true,
      trailing: Padding(
        // Same 9dp the chat composer keeps under its island.
        padding: const EdgeInsets.only(bottom: 9),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            PendingRequestsButton(
              color: tg.textPrimary,
              onPressed: () {
                final nav = navigatorKey.currentState;
                if (nav != null) openPendingRequests(nav);
              },
            ),
            IconButton(
              tooltip: l10n.settings,
              icon: const Icon(Icons.settings),
              color: tg.textPrimary,
              onPressed: () {
                final nav = navigatorKey.currentState;
                if (nav != null) openSettings(nav);
              },
            ),
          ],
        ),
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
    );
  }
}
