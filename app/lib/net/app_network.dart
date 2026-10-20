// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Platform-swapped network connector (TCP+SOCKS on IO, browser HTTP on web).

export 'package:resonchat/net/app_network_io.dart'
    if (dart.library.js_interop) 'package:resonchat/net/app_network_web.dart';
