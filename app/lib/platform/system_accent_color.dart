// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Entry point: read the desktop accent colour (Linux portal / GTK, Windows,
// macOS). Web has no system accent and resolves to null.

export 'package:resonchat/platform/system_accent_color_stub.dart'
    if (dart.library.io) 'package:resonchat/platform/system_accent_color_io.dart';
