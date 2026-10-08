// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Platform-swapped network connector (TCP+SOCKS on IO, browser HTTP on web).

export 'app_network_io.dart'
    if (dart.library.js_interop) 'app_network_web.dart';
