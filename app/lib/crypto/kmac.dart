// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// NIST SP 800-185 KMAC256 (cSHAKE256). Used by monocles OMEMO2 payload
// key derivation and key commitment (proto-XEP §5.4 / §5.5).

import 'dart:convert';
import 'dart:typed_data';

/// KMAC256(K, X, L_bits, S) → L_bits/8 bytes.
Uint8List kmac256({
  required List<int> key,
  required List<int> data,
  required int lengthBits,
  required String customization,
}) {
  if (lengthBits <= 0 || lengthBits % 8 != 0) {
    throw ArgumentError('lengthBits must be a positive multiple of 8');
  }
  const rate = 136; // cSHAKE256
  final newX = BytesBuilder(copy: false);
  newX.add(_bytepad(_encodeString(Uint8List.fromList(key)), rate));
  newX.add(data);
  newX.add(_rightEncode(lengthBits));
  return _cshake256(
    newX.toBytes(),
    lengthBits ~/ 8,
    n: const <int>[],
    s: utf8.encode(customization),
  );
}

Uint8List _cshake256(
  Uint8List x,
  int outLen, {
  required List<int> n,
  required List<int> s,
}) {
  const rate = 136;
  if (n.isEmpty && s.isEmpty) {
    // Reduces to SHAKE256 (domain 0x1F).
    return _keccak(x, rate, 0x1F, outLen);
  }
  final prefix = _bytepad(
    Uint8List.fromList([
      ..._encodeString(Uint8List.fromList(n)),
      ..._encodeString(Uint8List.fromList(s)),
    ]),
    rate,
  );
  final input = Uint8List(prefix.length + x.length);
  input.setAll(0, prefix);
  input.setAll(prefix.length, x);
  return _keccak(input, rate, 0x04, outLen);
}

Uint8List _encodeString(Uint8List s) {
  return Uint8List.fromList([..._leftEncode(s.length * 8), ...s]);
}

Uint8List _bytepad(Uint8List x, int w) {
  final enc = _leftEncode(w);
  final total = enc.length + x.length;
  final zeros = (w - (total % w)) % w;
  return Uint8List.fromList([...enc, ...x, ...List<int>.filled(zeros, 0)]);
}

Uint8List _leftEncode(int x) {
  final bytes = <int>[];
  var v = x;
  do {
    bytes.insert(0, v & 0xff);
    v >>= 8;
  } while (v > 0);
  return Uint8List.fromList([bytes.length, ...bytes]);
}

Uint8List _rightEncode(int x) {
  final bytes = <int>[];
  var v = x;
  do {
    bytes.insert(0, v & 0xff);
    v >>= 8;
  } while (v > 0);
  return Uint8List.fromList([...bytes, bytes.length]);
}

// --- Minimal Keccak-f[1600] sponge (FIPS 202) --------------------------------

const _roundConstants = <int>[
  0x0000000000000001,
  0x0000000000008082,
  0x800000000000808a,
  0x8000000080008000,
  0x000000000000808b,
  0x0000000080000001,
  0x8000000080008081,
  0x8000000000008009,
  0x000000000000008a,
  0x0000000000000088,
  0x0000000080008009,
  0x000000008000000a,
  0x000000008000808b,
  0x800000000000008b,
  0x8000000000008089,
  0x8000000000008003,
  0x8000000000008002,
  0x8000000000000080,
  0x000000000000800a,
  0x800000008000000a,
  0x8000000080008081,
  0x8000000000008080,
  0x0000000080000001,
  0x8000000080008008,
];

const _rho = <int>[
  0,
  1,
  62,
  28,
  27,
  36,
  44,
  6,
  55,
  20,
  3,
  10,
  43,
  25,
  39,
  41,
  45,
  15,
  21,
  8,
  18,
  2,
  61,
  56,
  14,
];

const _pi = <int>[
  0,
  10,
  20,
  5,
  15,
  16,
  1,
  11,
  21,
  6,
  7,
  17,
  2,
  12,
  22,
  23,
  8,
  18,
  3,
  13,
  14,
  24,
  9,
  19,
  4,
];

int _rotl64(int x, int n) {
  n %= 64;
  if (n == 0) return x;
  // Dart ints are arbitrary precision; mask to 64 bits.
  final u = x & 0xFFFFFFFFFFFFFFFF;
  return ((u << n) | (u >> (64 - n))) & 0xFFFFFFFFFFFFFFFF;
}

void _keccakF(Uint64List s) {
  final bc = Uint64List(5);
  final t = Uint64List(25);
  for (var round = 0; round < 24; round++) {
    for (var i = 0; i < 5; i++) {
      bc[i] = s[i] ^ s[i + 5] ^ s[i + 10] ^ s[i + 15] ^ s[i + 20];
    }
    for (var i = 0; i < 5; i++) {
      final d = bc[(i + 4) % 5] ^ _rotl64(bc[(i + 1) % 5], 1);
      for (var j = 0; j < 25; j += 5) {
        s[j + i] ^= d;
      }
    }
    t[0] = s[0];
    for (var i = 1; i < 25; i++) {
      t[_pi[i]] = _rotl64(s[i], _rho[i]);
    }
    for (var i = 0; i < 25; i++) {
      s[i] = t[i];
    }
    for (var j = 0; j < 25; j += 5) {
      for (var i = 0; i < 5; i++) {
        bc[i] = s[j + i];
      }
      for (var i = 0; i < 5; i++) {
        s[j + i] =
            bc[i] ^ ((~bc[(i + 1) % 5] & 0xFFFFFFFFFFFFFFFF) & bc[(i + 2) % 5]);
      }
    }
    s[0] ^= _roundConstants[round];
  }
}

Uint8List _keccak(Uint8List input, int rateBytes, int domain, int outLen) {
  final s = Uint64List(25);
  final block = Uint8List(rateBytes);
  var offset = 0;
  final n = input.length;
  while (n - offset >= rateBytes) {
    for (var i = 0; i < rateBytes; i++) {
      final lane = i >> 3;
      s[lane] ^= input[offset + i] << ((i & 7) * 8);
    }
    _keccakF(s);
    offset += rateBytes;
  }
  block.setRange(0, n - offset, input, offset);
  block[n - offset] = domain;
  block[rateBytes - 1] ^= 0x80;
  for (var i = 0; i < rateBytes; i++) {
    final lane = i >> 3;
    s[lane] ^= block[i] << ((i & 7) * 8);
  }
  _keccakF(s);

  final out = Uint8List(outLen);
  var got = 0;
  while (got < outLen) {
    final take = (outLen - got) < rateBytes ? (outLen - got) : rateBytes;
    for (var i = 0; i < take; i++) {
      out[got + i] = (s[i >> 3] >> ((i & 7) * 8)) & 0xff;
    }
    got += take;
    if (got < outLen) _keccakF(s);
  }
  return out;
}
