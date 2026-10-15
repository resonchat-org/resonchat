// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Floating main-tab capsule (portrait). Solid track + sliding thumb + ink
// ripples — same interaction model as the chats Messages/Unread filter.
// Glass / BackdropFilter were dropped so hover and splash stay visible.

import 'package:flutter/material.dart';

import '../theme.dart';

/// Capsule height (horizontal icon+label tabs).
const double kMainTabsHeight = 38;

/// Fixed width per tab — keeps the pill dense instead of edge-to-edge empty.
const double kMainTabWidth = 96;

/// Outer gap above the system inset.
const double kMainTabsMarginBottom = 12;

/// One destination in [MainTabsLayout].
class GlassTab {
  const GlassTab({
    required this.icon,
    required this.selectedIcon,
    required this.label,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
}

/// Floating capsule of main tabs with a sliding selection thumb.
class MainTabsLayout extends StatelessWidget {
  const MainTabsLayout({
    super.key,
    required this.selectedIndex,
    required this.onSelected,
    required this.tabs,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final List<GlassTab> tabs;

  /// Content inset: height + bottom margin.
  static const double contentInset = kMainTabsHeight + kMainTabsMarginBottom;

  static const _pad = 2.0;
  static const _slide = Duration(milliseconds: 220);

  @override
  Widget build(BuildContext context) {
    final tg = context.tg;
    final n = tabs.length;
    if (n == 0) return const SizedBox.shrink();

    // Match landscape [NavigationRail]: white/page track, darker accent
    // indicator pill, accent selected / textPrimary idle.
    final track = tg.pageBackground;
    final thumb = tg.accent.withValues(alpha: 0.12);
    const radius = kMainTabsHeight / 2;
    final index = selectedIndex.clamp(0, n - 1);
    final width = n * kMainTabWidth;

    return Material(
      color: track,
      elevation: 4,
      borderRadius: BorderRadius.circular(radius),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        height: kMainTabsHeight,
        width: width,
        child: Stack(
          children: [
            AnimatedPositioned(
              duration: _slide,
              curve: Curves.easeOutCubic,
              left: index * kMainTabWidth + _pad,
              top: _pad,
              bottom: _pad,
              width: kMainTabWidth - 2 * _pad,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: thumb,
                  borderRadius: BorderRadius.circular(radius - _pad),
                ),
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < n; i++)
                  SizedBox(
                    width: kMainTabWidth,
                    child: _TabHit(
                      tab: tabs[i],
                      selected: index == i,
                      selectedColor: tg.accent,
                      unselectedColor: tg.textPrimary,
                      onTap: () => onSelected(i),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TabHit extends StatelessWidget {
  const _TabHit({
    required this.tab,
    required this.selected,
    required this.selectedColor,
    required this.unselectedColor,
    required this.onTap,
  });

  final GlassTab tab;
  final bool selected;
  final Color selectedColor;
  final Color unselectedColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? selectedColor : unselectedColor;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(kMainTabsHeight / 2),
    );
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        customBorder: shape,
        onTap: onTap,
        child: SizedBox(
          height: kMainTabsHeight,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                selected ? tab.selectedIcon : tab.icon,
                size: 20,
                color: color,
              ),
              const SizedBox(width: 4),
              Flexible(
                child: AnimatedDefaultTextStyle(
                  duration: MainTabsLayout._slide,
                  curve: Curves.easeOutCubic,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                  child: Text(
                    tab.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
