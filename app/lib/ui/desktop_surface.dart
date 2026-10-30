// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Column-mode chrome: conversation nested in the list tray — not dual cards
// on a tinted canvas, and not stretched flush to the tray edges.

import 'package:flutter/material.dart';

import 'package:resonchat/ui/theme.dart';

/// Inset of the conversation from the tray's top / end / bottom.
const double kDesktopChatInset = 10;

/// Left-edge radius of the landscape main content (beside the rail).
const double kDesktopContentRadius = 16;

/// Corner radius of the nested conversation pane (all four corners).
const double kDesktopChatRadius = kDesktopContentRadius;

/// Slightly deepened page background for the list tray in column mode.
Color desktopListTrayOf(BuildContext context) {
  final page = context.appColors.pageBackground;
  final dark = page.computeLuminance() < 0.2;
  return Color.alphaBlend(
    Colors.black.withValues(alpha: dark ? 0.22 : 0.045),
    page,
  );
}

/// Conversation nested in the list tray: all-corner radius + border, not flush.
///
/// The landscape *main content* (beside the rail) stays left-edge-only; this
/// pane is the conversation card inset in the tray, so every corner is round.
class DesktopChatPane extends StatelessWidget {
  const DesktopChatPane({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tg = context.appColors;
    final radius = BorderRadius.circular(kDesktopChatRadius);
    return Padding(
      padding: const EdgeInsets.only(
        top: kDesktopChatInset,
        right: kDesktopChatInset,
        bottom: kDesktopChatInset,
      ),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: radius,
          border: Border.all(color: tg.separator),
        ),
        child: child,
      ),
    );
  }
}
