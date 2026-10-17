// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// App alias for omemo_dart's libsignal bootstrap (prefers vendor/libsignal_dart).

import 'package:omemo_dart/omemo_dart_omemo2.dart' show omemo2EnsureLibSignal;

/// App alias for [omemo2EnsureLibSignal].
Future<void> ensureLibSignal({String? libraryPath}) =>
    omemo2EnsureLibSignal(libraryPath: libraryPath);
