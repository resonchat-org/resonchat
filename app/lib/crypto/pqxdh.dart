// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// PQXDH key derivation. See docs/02-protocol-pqomemo.md §3.

import 'package:cryptography/cryptography.dart';

/// Output of the PQXDH handshake KDF: the session's root and chain keys.
class PqxdhResult {
  const PqxdhResult({required this.rootKey, required this.chainKey});

  final List<int> rootKey;
  final List<int> chainKey;
}

/// Derives `(rootKey, chainKey)` from the classic DH outputs and the
/// ML-KEM shared secrets:
///
/// ```
/// SK = HKDF-SHA512(
///        ikm  = F || DH1 || DH2 || DH3 || [DH4] || ss1 || [ss2],
///        salt = zeros(32),
///        info = "urn:xmpp:pomemo:0:pqxdh")  -> 64 bytes
/// ```
///
/// `dh4`/`ss2` are present only when a one-time prekey was used.
/// Security rests on either leg: breaking the session requires breaking
/// both X25519 and ML-KEM-768.
Future<PqxdhResult> derivePqxdh({
  required List<int> dh1,
  required List<int> dh2,
  required List<int> dh3,
  List<int>? dh4,
  required List<int> ss1,
  List<int>? ss2,
}) async {
  final ikm = <int>[
    ...List<int>.filled(32, 0xFF),
    ...dh1,
    ...dh2,
    ...dh3,
    ...?dh4,
    ...ss1,
    ...?ss2,
  ];
  final hkdf = Hkdf(hmac: Hmac.sha512(), outputLength: 64);
  final key = await hkdf.deriveKey(
    secretKey: SecretKey(ikm),
    nonce: List<int>.filled(32, 0),
    info: 'urn:xmpp:pomemo:0:pqxdh'.codeUnits,
  );
  final bytes = await key.extractBytes();
  return PqxdhResult(
    rootKey: bytes.sublist(0, 32),
    chainKey: bytes.sublist(32, 64),
  );
}

/// Raw X25519 agreement: `DH(ourPrivate, peerPublic)`, 32 bytes out.
Future<List<int>> x25519Agree(
  List<int> ourPrivateKey,
  List<int> peerPublicKey,
) async {
  final algorithm = X25519();
  final keyPair = await algorithm.newKeyPairFromSeed(ourPrivateKey);
  final remote = SimplePublicKey(peerPublicKey, type: KeyPairType.x25519);
  final secret = await algorithm.sharedSecretKey(
    keyPair: keyPair,
    remotePublicKey: remote,
  );
  return secret.extractBytes();
}
