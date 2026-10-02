// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// B-track (PQ-OMEMO) message layer.
//
// Structure mirrors the A track exactly (docs/02 §5), so the only
// difference is the namespace and the extra KEM ciphertexts in the KEX:
//
//   * the 32-byte message key is encrypted *with the double ratchet*
//     (via omemo_dart), producing one `<wrap>` per recipient device
//   * the payload is AES-256-GCM under that message key, once for all
//   * the first message to a device additionally carries the PQXDH
//     transcript (`kex="true"` plus `ek`, key ids and `<pqct>` elements)
//
// Reusing the ratchet verbatim is what keeps A and B tracks consistent and
// means only the handshake differs (ADR-002).

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:logging/logging.dart';
import 'package:omemo_dart/omemo_dart.dart' as omemo;

import 'message_codec.dart';
import 'pq_session.dart';

/// A ready-to-send B-track `<encrypted>` element.
class PqEncryptedOutgoing {
  const PqEncryptedOutgoing({required this.stanza, required this.deviceId});

  final PqEncryptedMessage stanza;
  final int deviceId;
}

/// Why a B-track message could not be opened. Callers keep the ciphertext
/// and render a placeholder instead of dropping it (docs/03 §5).
class PqDecryptError implements Exception {
  const PqDecryptError(this.reason);
  final String reason;
  @override
  String toString() => 'PqDecryptError: $reason';
}

/// Encrypts and decrypts B-track messages for one local device.
class PqMessageLayer {
  PqMessageLayer({
    required this.ownDevice,
    required this.sessions,
    required this.senderIkOf,
    Random? random,
  }) : _random = random ?? Random.secure();

  final Logger _log = Logger('PqMessageLayer');
  final Random _random;

  final PqDevice ownDevice;
  final PqSessionManager sessions;

  /// Resolves a remote device's X25519 identity public key, normally from
  /// its published bundle (a network round-trip the first time).
  ///
  /// Throws [PqDecryptError] when it cannot be fetched, rather than
  /// proceeding with a weaker session binding.
  final Future<List<int>> Function(int deviceId) senderIkOf;

  final _cipher = AesGcm.with256bits();

  List<int> _randomBytes(int n) =>
      Uint8List.fromList(List<int>.generate(n, (_) => _random.nextInt(256)));

  /// Encrypts [plaintext] for every device in [recipients].
  ///
  /// Returns null when no device could be served at all; the caller must
  /// then refuse to send rather than emit unreadable ciphertext
  /// (invariant 1, docs/01 §7).
  Future<PqEncryptedOutgoing?> encrypt({
    required String plaintext,
    required List<PqDevice> recipients,
  }) async {
    if (recipients.isEmpty) return null;

    // One message key protects the payload for everybody.
    final messageKey = _randomBytes(32);
    final payloadIv = _randomBytes(12);
    final payload = await _cipher.encrypt(
      utf8.encode(plaintext),
      secretKey: SecretKey(messageKey),
      nonce: payloadIv,
    );
    // `concatenation()` is ciphertext **plus zero padding** (GCM pads to a
    // block multiple), so it is not the wire format. Use cipherText and
    // append the tag explicitly.
    final payloadBytes = <int>[
      ...payload.cipherText,
      ...payload.mac.bytes,
    ];

    final keys = <PqKeyEntry>[];
    for (final peer in recipients) {
      try {
        keys.add(await _encryptForDevice(
          peer: peer,
          messageKey: messageKey,
        ));
      } catch (e) {
        _log.warning('could not encrypt for ${peer.jid}/${peer.id}: $e');
      }
    }

    if (keys.isEmpty) return null;

    return PqEncryptedOutgoing(
      stanza: PqEncryptedMessage(
        senderDeviceId: ownDevice.id,
        keys: keys,
        iv: base64Encode(payloadIv),
        payload: base64Encode(payloadBytes),
      ),
      deviceId: ownDevice.id,
    );
  }

  /// Produces the `<wrap>` (and KEX fields, on first contact) for one peer.
  Future<PqKeyEntry> _encryptForDevice({
    required PqDevice peer,
    required List<int> messageKey,
  }) async {
    PqKeyExchange? kex;
    // Ratchets are keyed by the remote device.
    var ratchet = sessions.ratchetFor(peer.jid, peer.id);

    if (ratchet == null) {
      kex = await sessions.initiate(own: ownDevice, peer: peer);
      ratchet = sessions.ratchetFor(peer.jid, peer.id);
    }
    if (ratchet == null) {
      throw StateError('no ratchet with ${peer.jid}/${peer.id}');
    }

    // The ratchet encrypts and authenticates the message key for us.
    // `writeToBuffer` produces the canonical protobuf encoding that
    // `ratchetDecrypt` expects, matching how the A track serialises it.
    final authenticated = await ratchet.ratchetEncrypt(messageKey);

    return PqKeyEntry(
      recipientDeviceId: peer.id,
      wrap: base64Encode(authenticated.writeToBuffer()),
      kex: kex != null,
      ek: kex == null ? null : base64Encode(kex.ekBytes),
      spkId: kex?.spkId,
      pkId: kex?.pkId,
      pqSpkId: kex?.pqSpkId,
      pqPkId: kex?.pqPkId,
      pqCiphertexts:
          kex == null ? const <String>[] : kex.pqCiphertexts.map(base64Encode).toList(),
    );
  }

  /// Decrypts [message] addressed to our own device.
  Future<String> decrypt(PqEncryptedMessage message) async {
    final entry = message.keys.firstWhere(
      (k) => k.recipientDeviceId == ownDevice.id,
      orElse: () => throw PqDecryptError(
        'not addressed to device ${ownDevice.id}',
      ),
    );

    // Build the session first when this is a KEX message.
    if (entry.kex ||
        !sessions.hasRatchet(ownDevice.jid, message.senderDeviceId)) {
      try {
        await sessions.accept(
          own: ownDevice,
          senderJid: ownDevice.jid,
          senderDeviceId: message.senderDeviceId,
          kex: entry,
          senderIkDh: await senderIkOf(message.senderDeviceId),
        );
      } on PqSessionError catch (e) {
        throw PqDecryptError('handshake failed: ${e.message}');
      }
    }

    final ratchet = sessions.ratchetFor(ownDevice.jid, message.senderDeviceId);
    if (ratchet == null) {
      throw PqDecryptError('no session with ${message.senderDeviceId}');
    }

    // Unwrap the message key through the ratchet. The `<wrap>` carries the
    // protobuf-serialised OMEMOAuthenticatedMessage, exactly as the A
    // track does.
    final authenticated = omemo.OMEMOAuthenticatedMessage.fromBuffer(
      base64Decode(entry.wrap),
    );

    final result = await ratchet.ratchetDecrypt(authenticated);
    if (!result.isType<List<int>>()) {
      throw PqDecryptError('ratchet rejected the message key');
    }
    final messageKey = result.get<List<int>>();
    if (messageKey.length != 32) {
      throw PqDecryptError(
        'recovered message key has length ${messageKey.length}, expected 32',
      );
    }

    // Open the payload. The IV travels in the `<iv>` element; the payload
    // holds ciphertext followed by the GCM tag.
    final nonce = base64Decode(message.iv);
    final raw = base64Decode(message.payload);
    final macLength = _cipher.macAlgorithm.macLength;
    final box = SecretBox(
      raw.sublist(0, raw.length - macLength),
      nonce: nonce,
      mac: Mac(raw.sublist(raw.length - macLength)),
    );
    try {
      final plaintext = await _cipher.decrypt(
        box,
        secretKey: SecretKey(messageKey),
      );
      return utf8.decode(plaintext);
    } catch (_) {
      throw const PqDecryptError('payload failed authentication');
    }
  }
}