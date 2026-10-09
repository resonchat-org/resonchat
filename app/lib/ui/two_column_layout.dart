// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// FluffyChat `TwoColumnLayout`: fixed-width list + expanded conversation.

import 'package:flutter/material.dart';

import 'column_mode.dart';

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
    final divider = Theme.of(context).dividerColor;
    return Row(
      children: [
        SizedBox(width: mainWidth, child: mainView),
        VerticalDivider(width: 1, thickness: 1, color: divider),
        Expanded(child: sideView),
      ],
    );
  }
}
