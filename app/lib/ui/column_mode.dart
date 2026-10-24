// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Wide-layout breakpoint. One width gate (≥ 600): side rail + master/detail.
// Below it, floating dock and stacked chat routes.

import 'package:flutter/material.dart';

/// Left pane width for the chat list in column mode (FluffyChat: 380).
const double kColumnListWidth = 360;

/// Width at which home uses the side rail and the chat list shares the screen
/// with a conversation (Material 3 "medium" window class).
const double kNavigationRailMinWidth = 600;

/// Master/detail (list + conversation) at the same width as the side rail.
bool isColumnModeByWidth(double width) => width >= kNavigationRailMinWidth;

bool isColumnMode(BuildContext context) =>
    isColumnModeByWidth(MediaQuery.sizeOf(context).width);

/// Whether navigation belongs on the side rather than in the floating dock.
///
/// Same width gate as [isColumnMode]: a tall desktop window still counts as
/// wide. Orientation-based chrome once put the phone dock over a composer on
/// an 886×965 Linux window.
bool usesNavigationRail(BuildContext context) => isColumnMode(context);
