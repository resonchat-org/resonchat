// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Process-wide ML-KEM providers. OMEMO2 uses ML-KEM-1024 via pure Dart
// (`pqcrypto`).

import 'mlkem.dart';
import 'pqcrypto_mlkem.dart';

/// Chooses the ML-KEM-1024 backend for monocles OMEMO2 (pure Dart).
class MlKem1024Provider {
  MlKem1024Provider._(this._kem);

  static MlKem1024Provider get instance =>
      _instance ??= MlKem1024Provider._(PqcryptoMlKem1024());
  static MlKem1024Provider? _instance;

  final MlKem1024 _kem;

  MlKem1024 get kem => _kem;
}

/// ML-KEM-768 for tests / diagnostics (pure Dart only).
class MlKem768Provider {
  MlKem768Provider._(this._kem);

  static MlKem768Provider get instance =>
      _instance ??= MlKem768Provider._(PqcryptoMlKem768());
  static MlKem768Provider? _instance;

  final MlKem768 _kem;

  MlKem768 get kem => _kem;
}
