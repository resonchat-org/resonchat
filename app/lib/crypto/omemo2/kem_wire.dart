// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// App-only ML-KEM wire predicate. serialize/parse live in omemo_dart
// (`omemo_dart_omemo2`); import those there, not via this file.

import 'package:omemo_dart/omemo_dart_omemo2.dart'
    show omemo2MlKem1024Tag, omemo2MlKemPublicKeyLength;

/// True when [serialized] is a tagged ML-KEM-1024 public key.
bool isMlKem1024PublicKey(List<int> serialized) {
  return serialized.isNotEmpty &&
      serialized[0] == omemo2MlKem1024Tag &&
      serialized.length == 1 + omemo2MlKemPublicKeyLength;
}
