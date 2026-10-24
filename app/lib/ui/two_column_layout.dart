// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// FluffyChat `TwoColumnLayout`: fixed-width list + expanded conversation.
//
// The two panes are cards on a tinted canvas, with a gutter between them,
// instead of one surface split by a vertical divider. The old 1 px line
// looked like a hard seam at desktop widths; the gutter also gives the
// conversation's wallpaper an edge of its own.

import 'package:flutter/material.dart';

import 'package:resonchat/ui/column_mode.dart';
import 'package:resonchat/ui/desktop_surface.dart';

class TwoColumnLayout extends StatelessWidget {
  const TwoColumnLayout({
    super.key,
    required this.mainView,
    required this.sideView,
    this.mainWidth = kColumnListWidth,
  });

  final Widget mainView;
  final Widget sideView;
  final double mainWidth;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: desktopCanvasOf(context),
      child: Row(
        children: [
          SizedBox(width: mainWidth, child: DesktopPane(child: mainView)),
          const SizedBox(width: kDesktopGutter),
          Expanded(child: DesktopPane(child: sideView)),
        ],
      ),
    );
  }
}
