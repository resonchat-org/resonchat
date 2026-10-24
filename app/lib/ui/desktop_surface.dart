// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Desktop split chrome.
//
// Wide windows used to join the panes with a one-pixel `VerticalDivider`.
// At 1600 px wide that reads as a hard seam: the list is white, the
// conversation carries its wallpaper, and the line is the only thing between
// them. Instead the panes are separate rounded cards floating on a tinted
// canvas, with a real gutter between them — the same visual grammar as the
// mockup the layout was asked to follow.

import 'package:flutter/material.dart';

import 'package:resonchat/ui/theme.dart';

/// Space between the rail, the chat list and the conversation, and around
/// the whole split.
const double kDesktopGutter = 10;

/// Corner radius of every wider-than-phone pane.
const double kDesktopPaneRadius = 16;

/// Tint behind the panes.
///
/// Derived from the accent so it follows the chosen theme (a purple accent
/// gives the lavender canvas of the mockup; the default blue stays blue).
/// The panes themselves keep their own surface colour, so this is only ever
/// visible as a gutter or in the rounded corners.
Color desktopCanvasOf(BuildContext context) {
  final tg = context.tg;
  final dark = tg.pageBackground.computeLuminance() < 0.2;
  return Color.alphaBlend(
    tg.accent.withValues(alpha: dark ? 0.16 : 0.07),
    tg.pageBackground,
  );
}

/// One rounded surface on the desktop canvas.
///
/// The child is expected to paint its own background (every page and chat is
/// a `Scaffold`); clipping is what turns it into a card.
class DesktopPane extends StatelessWidget {
  const DesktopPane({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(kDesktopPaneRadius),
      child: child,
    );
  }
}
