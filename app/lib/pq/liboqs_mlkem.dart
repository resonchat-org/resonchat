// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Process-wide ML-KEM provider. Native liboqs is loaded via [mlkem_native]
// (IO only); web always uses pure Dart.

import 'mlkem.dart';
import 'mlkem_native.dart';
import 'pqcrypto_mlkem.dart';

export 'mlkem_native.dart';

/// Chooses the best available ML-KEM-768 backend once per process.
///
/// Android gets liboqs; everything else (desktop, tests, web) keeps the
/// pure-Dart path, which is correct everywhere but slower. Both are
/// proven equivalent in `test/mlkem_interop_test.dart`.
class MlKem768Provider {
  MlKem768Provider._(this._kem, {required this.isNative});

  static MlKem768Provider get instance => _instance ??= _resolve();
  static MlKem768Provider? _instance;

  static MlKem768Provider _resolve() {
    final native = loadNativeMlKem();
    if (native != null) {
      return MlKem768Provider._(native, isNative: true);
    }
    return MlKem768Provider._(PqcryptoMlKem768(), isNative: false);
  }

  final MlKem768 _kem;

  /// The active implementation.
  MlKem768 get kem => _kem;

  /// True when the native liboqs backend is in use.
  final bool isNative;
}

/// Compatibility alias for settings / diagnostics.
String? get liboqsLoadError => nativeMlKemLoadError;
