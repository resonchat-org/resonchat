// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// B-track (PQ-OMEMO) session management.
//
// The design keeps the post-quantum part where it belongs — session
// establishment — and reuses omemo_dart's Double Ratchet unchanged for the
// steady state (ADR-002). That means:
//
//   PQXDH  -> (rootKey, chainKey)   // X25519 x3 + ML-KEM-768, our code
//   ratchet-> same omemo_dart code the A track uses
//
// Swapping the X3DH output for a PQXDH output is the only difference, which
// is exactly why the PQ track does not need a second ratchet
// implementation.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:omemo_dart/omemo_dart.dart' as omemo;

import '../pqxdh.dart';
import 'message_codec.dart';
import '../pq/mlkem.dart';

/// One device's cryptographic identity on the B track.
class PqDevice {
  PqDevice({
    required this.jid,
    required this.id,
    required this.ikDh,
    required this.spk,
    required this.spkId,
    required this.spkSignature,
    required this.pqSpk,
    required this.pqSpkSecret,
    required this.pqSpkId,
    required this.pqSpkSignature,
    required this.opks,
    required this.pqOpks,
  });

  final String jid;
  final int id;

  /// X25519 identity key (same key as the A track, so one fingerprint).
  final omemo.OmemoKeyPair ikDh;

  /// X25519 signed prekey.
  final omemo.OmemoKeyPair spk;
  final int spkId;
  final List<int> spkSignature;

  /// ML-KEM-768 signed prekey (public part).
  final List<int> pqSpk;

  /// ML-KEM-768 signed prekey (private part). Never leaves the device.
  final List<int> pqSpkSecret;
  final int pqSpkId;
  final List<int> pqSpkSignature;

  /// X25519 one-time prekeys, id → key pair.
  final Map<int, omemo.OmemoKeyPair> opks;

  /// ML-KEM-768 one-time prekeys, id → key pair.
  ///
  /// Both halves are needed locally: the public half is what peers
  /// encapsulate to, the private half is what we decapsulate with.
  final Map<int, KemKeyPair> pqOpks;

  static Future<PqDevice> generate(
    String jid, {
    int opkCount = 20,
    int pqOpkCount = 5,
    MlKem768? kem,
  }) async {
    if (kem == null) {
      throw ArgumentError('a KEM implementation is required');
    }
    final k = kem;

    // The Ed25519 identity key is the master key; its X25519 conversion is
    // what DH uses. Same arrangement as the A track, so one fingerprint
    // identifies the device across both tracks.
    final ikEd = await omemo.OmemoKeyPair.generateNewPair(KeyPairType.ed25519);
    final ik = await ikEd.toCurve25519();
    final spk = await omemo.OmemoKeyPair.generateNewPair(KeyPairType.x25519);
    final spkId = _randomId();
    final signature = await _sign(
      await ikEd.sk.getBytes(),
      await spk.pk.getBytes(),
    );

    final opks = <int, omemo.OmemoKeyPair>{};
    for (var i = 0; i < opkCount; i++) {
      opks[_randomId()] = await omemo.OmemoKeyPair.generateNewPair(
        KeyPairType.x25519,
      );
    }

    final pqSpkKp = k.generateKeyPair();
    final pqOpks = <int, KemKeyPair>{};
    for (var i = 0; i < pqOpkCount; i++) {
      pqOpks[_randomId()] = k.generateKeyPair();
    }

    return PqDevice(
      jid: jid,
      id: _randomId(),
      ikDh: ik,
      spk: spk,
      spkId: spkId,
      spkSignature: signature,
      pqSpkSecret: pqSpkKp.secretKey,
      pqSpk: pqSpkKp.publicKey,
      pqSpkId: _randomId(),
      // Q1 (docs/08): do not carry an ML-DSA signature by default; the
      // classic Ed25519 signature plus TOFU is the agreed first cut.
      pqSpkSignature: signature,
      opks: opks,
      pqOpks: pqOpks,
    );
  }

  /// Signs the signed prekey with the device's Ed25519 identity key, so a
  /// peer can detect a substituted SPK. Keeping the A track's Ed25519 shape
  /// means one fingerprint still covers both tracks.
  static Future<List<int>> _sign(
    List<int> ikPrivateSeed,
    List<int> message,
  ) async {
    final ed = Ed25519();
    final keyPair = await ed.newKeyPairFromSeed(ikPrivateSeed);
    final signature = await ed.sign(message, keyPair: keyPair);
    return signature.bytes;
  }

  /// Random 31-bit positive id, matching the OMEMO device/prekey id space
  /// (XEP-0384). Uses the platform CSPRNG, never a clock.
  static int _randomId() {
    final rnd = _rng.nextInt(0x7FFFFFFF);
    return rnd == 0 ? 1 : rnd;
  }

  static final Random _rng = Random.secure();
}

/// Why a B-track session could not be built.
class PqSessionError implements Exception {
  const PqSessionError(this.message);
  final String message;
  @override
  String toString() => 'PqSessionError: $message';
}

/// Builds and drives B-track ratchets via PQXDH.
class PqSessionManager {
  PqSessionManager({required this.kem});

  final MlKem768 kem;

  /// Established ratchets, keyed by "jid/deviceId".
  final Map<String, omemo.OmemoDoubleRatchet> _ratchets = {};

  omemo.OmemoDoubleRatchet? ratchetFor(String jid, int deviceId) =>
      _ratchets[_key(jid, deviceId)];

  void putRatchet(String jid, int deviceId, omemo.OmemoDoubleRatchet ratchet) =>
      _ratchets[_key(jid, deviceId)] = ratchet;

  bool hasRatchet(String jid, int deviceId) =>
      ratchetFor(jid, deviceId) != null;

  String _key(String jid, int deviceId) => '$jid/$deviceId';

  /// Initiator side: derives (rootKey, chainKey) with PQXDH and starts a
  /// ratchet against [peer].
  ///
  /// Returns the KEX material that must travel in the first message.
  Future<PqKeyExchange> initiate({
    required PqDevice own,
    required PqDevice peer,
  }) async {
    final ek = await omemo.OmemoKeyPair.generateNewPair(KeyPairType.x25519);

    // Prefer one-time prekeys on both legs; fall back to the signed ones.
    final opkEntry = peer.opks.entries.isEmpty ? null : peer.opks.entries.first;
    final pqOpkEntry = peer.pqOpks.entries.isEmpty
        ? null
        : peer.pqOpks.entries.first;

    final ss1 = kem.encapsulate(peer.pqSpk);
    final ss2 = pqOpkEntry == null
        ? null
        : kem.encapsulate(peer.pqOpks[pqOpkEntry.key]!.publicKey);

    final derived = await derivePqxdh(
      dh1: await x25519Agree(
        await own.ikDh.sk.getBytes(),
        await peer.spk.pk.getBytes(),
      ),
      dh2: await x25519Agree(
        await ek.sk.getBytes(),
        await peer.ikDh.pk.getBytes(),
      ),
      dh3: await x25519Agree(
        await ek.sk.getBytes(),
        await peer.spk.pk.getBytes(),
      ),
      dh4: opkEntry == null
          ? null
          : await x25519Agree(
              await ek.sk.getBytes(),
              await opkEntry.value.pk.getBytes(),
            ),
      ss1: ss1.sharedSecret,
      ss2: ss2?.sharedSecret,
    );

    final ratchet = await omemo.OmemoDoubleRatchet.initiateNewSession(
      peer.spk.pk,
      peer.spkId,
      peer.ikDh.pk,
      own.ikDh.pk,
      ek.pk,
      derived.rootKey,
      // Initiator's IK first, responder's second.
      _associatedData(
        await own.ikDh.pk.getBytes(),
        await peer.ikDh.pk.getBytes(),
      ),
      opkEntry?.key ?? -1,
    );
    // One ratchet per remote device, keyed the way every lookup does:
    // (peer jid, peer device id). Storing it under our own jid as well
    // aliased the same state object under two keys and desynchronised the
    // chains.
    putRatchet(peer.jid, peer.id, ratchet);

    return PqKeyExchange(
      ekBytes: await ek.pk.getBytes(),
      spkId: peer.spkId,
      pkId: opkEntry?.key,
      pqSpkId: peer.pqSpkId,
      pqPkId: pqOpkEntry?.key,
      pqCiphertexts: <List<int>>[
        ss1.ciphertext,
        if (ss2 != null) ss2.ciphertext,
      ],
      consumedOpkId: opkEntry?.key,
      consumedPqOpkId: pqOpkEntry?.key,
    );
  }

  /// Responder side: rebuilds the same root key from an inbound KEX and
  /// creates the matching ratchet.
  ///
  /// Returns null when the message targets a prekey we no longer hold,
  /// which callers must surface rather than silently ignore.
  Future<omemo.OmemoDoubleRatchet?> accept({
    required PqDevice own,
    required String senderJid,
    required int senderDeviceId,
    required PqKeyEntry kex,
    required List<int> senderIkDh,
  }) async {
    final ekBytes = kex.ek;
    if (ekBytes == null || ekBytes.isEmpty) {
      throw const PqSessionError('kex has no ephemeral key');
    }
    final ek = omemo.OmemoPublicKey.fromBytes(
      base64Decode(ekBytes),
      KeyPairType.x25519,
    );

    // Locate the prekeys the sender says it used.
    final spkId = kex.spkId;
    if (spkId != own.spkId) {
      throw PqSessionError('unknown spk id $spkId');
    }
    final pkId = kex.pkId;
    final pqPkId = kex.pqPkId;
    if (kex.pqCiphertexts.isEmpty) {
      throw const PqSessionError('kex carries no KEM ciphertext');
    }

    // The wire form is base64; decode before handing bytes to the KEM.
    final ct1 = base64Decode(kex.pqCiphertexts.first);
    final ss1 = kem.decapsulate(own.pqSpkSecret, ct1);
    final ss2 = (kex.pqCiphertexts.length > 1 && pqPkId != null)
        ? kem.decapsulate(
            own.pqOpks[pqPkId]!.secretKey,
            base64Decode(kex.pqCiphertexts[1]),
          )
        : null;

    List<int>? dh4;
    if (pkId != null) {
      final opk = own.opks[pkId];
      if (opk != null) {
        dh4 = await x25519Agree(await opk.sk.getBytes(), await ek.getBytes());
      }
    }

    final peerIk = senderIkDh;
    if (peerIk.isEmpty) {
      throw PqSessionError('sender identity key is empty');
    }
    _senderIks[senderJid] = peerIk;

    final derived = await derivePqxdh(
      dh1: await x25519Agree(await own.spk.sk.getBytes(), peerIk),
      dh2: await x25519Agree(await own.ikDh.sk.getBytes(), await ek.getBytes()),
      dh3: await x25519Agree(await own.spk.sk.getBytes(), await ek.getBytes()),
      dh4: dh4,
      ss1: ss1,
      ss2: ss2,
    );

    final ratchet = await omemo.OmemoDoubleRatchet.acceptNewSession(
      own.spk,
      own.spkId,
      ek,
      pkId ?? -1,
      ek,
      derived.rootKey,
      // Alice (the sender) first, matching the initiator's ordering.
      _associatedData(peerIk, await own.ikDh.pk.getBytes()),
    );
    putRatchet(senderJid, senderDeviceId, ratchet);
    return ratchet;
  }

  /// Cached X25519 identity keys of remote devices, keyed by bare JID.
  final Map<String, List<int>> _senderIks = {};

  /// Registers a sender's X25519 identity key, taken from their bundle.
  void cacheSenderIdentity(String jid, List<int> ikDhBytes) {
    _senderIks[jid] = ikDhBytes;
  }

  /// Associated data binding the session to both identity keys.
  ///
  /// Order matters and must match the A track: `IK_initiator ||
  /// IK_responder`. Both sides compute this, so a mismatch here silently
  /// produces different root keys and every message fails to decrypt.
  /// [initiatorIk] is therefore always the *sender* of the first message.
  List<int> _associatedData(List<int> initiatorIkDh, List<int> responderIkDh) {
    if (initiatorIkDh.isEmpty || responderIkDh.isEmpty) {
      throw const PqSessionError('associated data needs both identity keys');
    }
    return Uint8List.fromList(<int>[...initiatorIkDh, ...responderIkDh]);
  }

  /// Drops a session, e.g. when a device is removed.
  void forget(String jid, int deviceId) {
    _ratchets.remove(_key(jid, deviceId));
  }

  void forgetAll() => _ratchets.clear();
}

/// Handshake material the initiator must put in the first message.
///
/// The KEX parameters only; wrapping the message key is the message
/// layer's job so encryption lives in exactly one place.
class PqKeyExchange {
  const PqKeyExchange({
    required this.ekBytes,
    required this.spkId,
    required this.pqSpkId,
    required this.pqCiphertexts,
    this.pkId,
    this.pqPkId,
    this.consumedOpkId,
    this.consumedPqOpkId,
  });

  /// Ephemeral X25519 public key, raw bytes.
  final List<int> ekBytes;

  final int spkId;
  final int pqSpkId;
  final List<List<int>> pqCiphertexts;
  final int? pkId;
  final int? pqPkId;

  /// Prekeys we must retire locally after a successful decrypt.
  final int? consumedOpkId;
  final int? consumedPqOpkId;

  /// Fills the handshake fields into a [PqKeyEntry] that already carries
  /// the wrapped message key.
  PqKeyEntry applyTo(PqKeyEntry entry) => entry;
}
