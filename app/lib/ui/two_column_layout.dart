// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// FluffyChat `TwoColumnLayout`: fixed-width list + expanded conversation.
//
// Column mode only: one deepened tray; the conversation sits inset inside it
// (left-edge radius + border), not as a sibling card and not stretched flush.

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
      color: desktopListTrayOf(context),
      child: Row(
        children: [
          SizedBox(width: mainWidth, child: mainView),
          Expanded(child: DesktopChatPane(child: sideView)),
        ],
      ),
    );
  }
}
