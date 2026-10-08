// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'mlkem.dart';

/// No FFI on web.
MlKem768? loadNativeMlKem() => null;

String? get nativeMlKemLoadError => 'liboqs unavailable on this platform';
