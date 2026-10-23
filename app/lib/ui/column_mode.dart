// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Wide-layout breakpoint (FluffyChat `FluffyThemes.isColumnMode`, Conversations
// tablet master/detail). Above this width the chat list and a conversation
// share the screen; below it, navigation stays a stacked route.

import 'package:flutter/material.dart';

/// Left pane width for the chat list in column mode (FluffyChat: 380).
const double kColumnListWidth = 360;

/// Master/detail when the window is wider than two list panes.
bool isColumnModeByWidth(double width) => width > kColumnListWidth * 2;

bool isColumnMode(BuildContext context) =>
    isColumnModeByWidth(MediaQuery.sizeOf(context).width);

/// Width at which home navigation moves from the bottom dock to the side rail
/// (Material 3 "medium" window class).
const double kNavigationRailMinWidth = 600;

/// Whether navigation belongs on the side rather than in the floating dock.
///
/// This is a *width* rule, not an orientation rule: a tall window on a desktop
/// is still a desktop window. Testing orientation put the phone's floating dock
/// over a 886×965 Linux window, covering the composer while 886 px of width sat
/// unused. Same width breakpoint on every platform keeps phone landscape (the
/// rail fits there too) and small windows consistent.
bool usesNavigationRail(BuildContext context) =>
    MediaQuery.sizeOf(context).width >= kNavigationRailMinWidth;
