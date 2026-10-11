// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Floating main-tab bar translated from Telegram for Android's
// `MainTabsLayout` + `GlassTabView` + `BlurredBackgroundProviderImpl.mainTabs`
// (GPL-2.0-or-later).
//
// Colour mapping (Theme.java fallbacks → our [TgColors]):
//   key_glass_tabSelected / SelectedText → key_chat_messagePanelSend → accent
//   key_glass_tabUnselected → key_windowBackgroundWhiteBlackText → textPrimary
//   glass fill → windowBackgroundWhite @ ~0.76–0.85 → pageBackground @ alpha
//
// Geometry: DialogsActivity.MAIN_TABS_HEIGHT=56, MAIN_TABS_MARGIN=8, radius =
// height/2. We keep icon+label horizontal (shorter than Telegram's vertical
// GlassTabView) but the capsule still uses the same margin / pill radius rules.

import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme.dart';

/// Capsule height. Telegram's `MAIN_TABS_HEIGHT` is 56 for vertical
/// icon-over-label tabs; ours are horizontal, so a shorter pill fits.
const double kMainTabsHeight = 44;

/// Telegram `DialogsActivity.MAIN_TABS_MARGIN`.
const double kMainTabsMargin = 8;

/// One destination in [MainTabsLayout] (Telegram `GlassTabView`).
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

/// Telegram `MainTabsLayout`: floating glass capsule of main tabs.
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

  /// Content inset: height + bottom margin (Telegram MAIN_TABS_HEIGHT_WITH_MARGINS
  /// is height + 2×margin; lists only need the bottom clearance).
  static const double contentInset = kMainTabsHeight + kMainTabsMargin;

  @override
  Widget build(BuildContext context) {
    final tg = context.tg;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // BlurredBackgroundProviderImpl.mainTabs: windowBackgroundWhite @ 0.76
    // (0.85 with liquid glass). Mapped to our page background.
    final fill = tg.pageBackground.withValues(alpha: isDark ? 0.85 : 0.76);
    // setStrokeColorTop / Bottom approximations.
    final border = isDark ? const Color(0x11FFFFFF) : const Color(0x11000000);
    // setShadowColor + setShadowLayer(~2.67, 0, 0.85).
    final shadow = isDark ? const Color(0x04000000) : const Color(0x20000000);

    // Fully rounded ends: Telegram setRadius(MAIN_TABS_HEIGHT / 2).
    const radius = kMainTabsHeight / 2;

    // Shadow outside the clip (Telegram setShadowLayer sits under the glass).
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: [
          BoxShadow(
            color: shadow,
            blurRadius: 2.67,
            offset: const Offset(0, 0.85),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        elevation: 0,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(radius),
                border: Border.all(color: border, width: 0.4),
              ),
              child: SizedBox(
                height: kMainTabsHeight,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Row(
                    children: [
                      for (var i = 0; i < tabs.length; i++)
                        Expanded(
                          child: _GlassTabButton(
                            tab: tabs[i],
                            selected: selectedIndex == i,
                            // Theme.key_glass_tabSelected / SelectedText
                            selectedColor: tg.accent,
                            // Theme.key_glass_tabUnselected
                            unselectedColor: tg.textPrimary,
                            onTap: () => onSelected(i),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _GlassTabButton extends StatelessWidget {
  const _GlassTabButton({
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
    return InkWell(
      onTap: onTap,
      // GlassTabView selected pill uses half of the tab height as corner radius.
      borderRadius: BorderRadius.circular(kMainTabsHeight / 2),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        alignment: Alignment.center,
        // GlassTabView: Theme.multAlpha(colorSelected, 0.09).
        decoration: BoxDecoration(
          color: selected
              ? selectedColor.withValues(alpha: 0.09)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(kMainTabsHeight / 2),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              selected ? tab.selectedIcon : tab.icon,
              size: 22,
              color: color,
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                tab.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  // GlassTabView text is 12sp bold.
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
