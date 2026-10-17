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
