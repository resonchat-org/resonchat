// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// ML-KEM interfaces. OMEMO2 uses ML-KEM-1024 (monocles); ML-KEM-768 is
// retained for native-bridge / interop tests only.

/// A freshly generated ML-KEM key pair (raw FIPS 203 bytes, no type tag).
class KemKeyPair {
  const KemKeyPair({required this.publicKey, required this.secretKey});

  final List<int> publicKey;
  final List<int> secretKey;
}

/// Result of encapsulating to a peer's public key.
class KemEncapsulation {
  const KemEncapsulation({
    required this.ciphertext,
    required this.sharedSecret,
  });

  final List<int> ciphertext;
  final List<int> sharedSecret;
}

/// ML-KEM-1024 (FIPS 203) — monocles OMEMO2 / proto-XEP.
abstract class MlKem1024 {
  static const int publicKeyLength = 1568;
  static const int secretKeyLength = 3168;
  static const int ciphertextLength = 1568;
  static const int sharedSecretLength = 32;

  KemKeyPair generateKeyPair();

  KemEncapsulation encapsulate(List<int> publicKey);

  /// Returns the 32-byte shared secret. ML-KEM uses implicit rejection.
  List<int> decapsulate(List<int> secretKey, List<int> ciphertext);
}

/// ML-KEM-768 (FIPS 203) — legacy tests / optional native bridge.
abstract class MlKem768 {
  static const int publicKeyLength = 1184;
  static const int secretKeyLength = 2400;
  static const int ciphertextLength = 1088;
  static const int sharedSecretLength = 32;

  KemKeyPair generateKeyPair();

  KemEncapsulation encapsulate(List<int> publicKey);

  List<int> decapsulate(List<int> secretKey, List<int> ciphertext);
}
