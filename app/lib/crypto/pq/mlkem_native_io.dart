// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'liboqs_mlkem_io.dart';
import 'mlkem.dart';

/// Native liboqs backend when the bridge loads; otherwise null.
MlKem768? loadNativeMlKem() => LiboqsMlKem768.tryLoad();

/// Last load failure reason from the FFI bridge, if any.
String? get nativeMlKemLoadError => LiboqsMlKem768.loadError;
