// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// ML-KEM-768 interface. Pure-Dart start (`pqcrypto`); a liboqs FFI
// implementation can be dropped in later behind this same interface.

/// A freshly generated ML-KEM key pair.
class KemKeyPair {
  const KemKeyPair({required this.publicKey, required this.secretKey});

  /// Encapsulation key (1184 bytes for ML-KEM-768).
  final List<int> publicKey;

  /// Decapsulation key (2400 bytes for ML-KEM-768).
  final List<int> secretKey;
}

/// Result of encapsulating to a peer's public key.
class KemEncapsulation {
  const KemEncapsulation({
    required this.ciphertext,
    required this.sharedSecret,
  });

  /// Ciphertext to send to the peer (1088 bytes for ML-KEM-768).
  final List<int> ciphertext;

  /// Shared secret established with the peer (32 bytes).
  final List<int> sharedSecret;
}

/// ML-KEM-768 operations. Implementations must be deterministic in sizes
/// and agree on shared secrets (ciphertexts may differ).
abstract class MlKem768 {
  static const int publicKeyLength = 1184;
  static const int secretKeyLength = 2400;
  static const int ciphertextLength = 1088;
  static const int sharedSecretLength = 32;

  KemKeyPair generateKeyPair();

  KemEncapsulation encapsulate(List<int> publicKey);

  /// Returns the 32-byte shared secret. ML-KEM uses implicit rejection:
  /// invalid inputs yield a pseudo-random secret instead of throwing,
  /// so callers must not treat the output as an error signal.
  List<int> decapsulate(List<int> secretKey, List<int> ciphertext);
}
