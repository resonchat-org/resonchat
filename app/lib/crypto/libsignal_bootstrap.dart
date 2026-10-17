// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Re-export omemo_dart's libsignal bootstrap (prefers vendor/libsignal_dart).

export 'package:omemo_dart/omemo_dart_omemo2.dart' show omemo2EnsureLibSignal;

import 'package:omemo_dart/omemo_dart_omemo2.dart';

/// App alias for [omemo2EnsureLibSignal].
Future<void> ensureLibSignal({String? libraryPath}) =>
    omemo2EnsureLibSignal(libraryPath: libraryPath);
