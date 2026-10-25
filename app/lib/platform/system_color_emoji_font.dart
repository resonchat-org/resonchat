// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Entry point: Linux loads the system colour emoji TTF; elsewhere is a no-op.

export 'package:resonchat/platform/system_color_emoji_font_stub.dart'
    if (dart.library.io) 'package:resonchat/platform/system_color_emoji_font_io.dart';
