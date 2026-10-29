// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// monocles `<pq-auth>` handshake authentication (proto-XEP §4.9.7).

import 'dart:convert';
import 'dart:typed_data';

import 'package:hex/hex.dart';
import 'package:logging/logging.dart';
import 'package:omemo_dart/omemo_dart_omemo2.dart';

import 'package:resonchat/crypto/omemo2/message_codec.dart';
import 'package:resonchat/persistence/pq_identity_store.dart';

final _log = Logger('PqAuth');

/// Raised when a pre-key message lacks a valid `<pq-auth>` or pin mismatch.
class PqHandshakeAuthException implements Exception {
  PqHandshakeAuthException(this.message);
  final String message;
  @override
  String toString() => 'PqHandshakeAuthException: $message';
}

/// `<pq-auth>` verified, but names a different PQ key than the pinned one.
class PqIdentityChangedException extends PqHandshakeAuthException {
  PqIdentityChangedException(this.name, this.ikFingerprint)
    : super(
        'post-quantum identity of $name CHANGED — refusing the handshake; '
        're-verify the contact\'s hybrid fingerprint to accept the new key',
      );

  final String name;
  final String ikFingerprint;
}

/// Result of verifying a handshake for our device.
class VerifiedHandshake {
  const VerifiedHandshake({
    required this.senderName,
    required this.ikFingerprint,
    required this.pqIdentityKey,
    required this.newlyPinned,
  });

  final String senderName;
  final String ikFingerprint;
  final Uint8List pqIdentityKey;
  final bool newlyPinned;
}

/// Looks up / writes the PQ identity pinned for (bare JID, classical IK hex).
abstract class PqIdentityPins {
  Future<Uint8List?> pinnedPqIdentity(String name, String ikFingerprint);

  /// Atomically pin unless something is already pinned; returns the key
  /// pinned afterwards (may differ when a concurrent pin won).
  Future<Uint8List> pinIfAbsent(
    String name,
    String ikFingerprint,
    Uint8List pqIdentityKey,
  );
}

/// Collect every `<key kex='true'>` exactly as written for the transcript.
List<Omemo2KexAuthEntry> kexAuthEntriesFromMessage(PqEncryptedMessage message) {
  final out = <Omemo2KexAuthEntry>[];
  for (final group in message.recipients) {
    final slash = group.jid.indexOf('/');
    final bare = slash < 0 ? group.jid : group.jid.substring(0, slash);
    for (final k in group.keys) {
      if (!k.kex) continue;
      try {
        final data = base64Decode(k.ciphertext);
        out.add(
          Omemo2KexAuthEntry(
            jid: bare,
            rid: k.recipientDeviceId,
            keyBytes: Uint8List.fromList(data),
          ),
        );
      } catch (_) {
        // unparsable content: not part of the transcript (sender and receiver)
      }
    }
  }
  return out;
}

/// Sign `<pq-auth>` for an outgoing header that carries at least one kex key.
Future<PqAuthSignature> signPqAuth({
  required Omemo2Device ownDevice,
  required PqIdentityStore pqIdentity,
  required String senderBareJid,
  required int sid,
  required List<Omemo2KexAuthEntry> entries,
}) async {
  await ownDevice.ensureStores();
  final ik = await ownDevice.identityPublicSerialized();
  final pqIk = await pqIdentity.publicKey();
  final transcript = omemo2KexAuthTranscript(
    senderBareJid: senderBareJid,
    sid: sid,
    identityKey: ik,
    pqIdentityKey: pqIk,
    entries: entries,
  );
  final pqSig = await pqIdentity.sign(transcript);
  final ikSig = await ownDevice.sign(transcript);
  return PqAuthSignature(
    pqIdentityKey: pqIk,
    pqSignature: pqSig,
    ikSignature: ikSig,
  );
}

/// monocles `verifyHandshake`: null when our device has no kex key.
///
/// Must run **before** libsignal processes any PreKeySignalMessage.
Future<VerifiedHandshake?> verifyHandshake({
  required PqEncryptedMessage message,
  required String senderBareJid,
  required String ownBareJid,
  required int ownDeviceId,
  required PqIdentityPins pins,
}) async {
  Uint8List? senderIk;
  var ownKex = false;
  for (final group in message.recipients) {
    final slash = group.jid.indexOf('/');
    final bare = (slash < 0 ? group.jid : group.jid.substring(0, slash))
        .toLowerCase();
    if (bare != ownBareJid.toLowerCase()) continue;
    for (final k in group.keys) {
      if (k.recipientDeviceId != ownDeviceId || !k.kex) continue;
      try {
        final raw = base64Decode(k.ciphertext);
        final preKey = Omemo2PreKeySignalMessage.fromSerialized(
          Uint8List.fromList(raw),
        );
        final ik = Uint8List.fromList(preKey.identityKey.serialize());
        ownKex = true;
        if (senderIk != null && !_bytesEq(senderIk, ik)) {
          throw PqHandshakeAuthException(
            'pre-key messages for this device name different identity keys',
          );
        }
        senderIk = ik;
      } catch (e) {
        if (e is PqHandshakeAuthException) rethrow;
        _log.warning('OMEMO2: skipping malformed pre-key message candidate');
      }
    }
  }
  if (!ownKex) return null;

  final pqAuth = message.pqAuth;
  if (pqAuth == null) {
    throw PqHandshakeAuthException(
      'pre-key message without a valid <pq-auth> — the sender\'s client '
      'predates handshake authentication and must be updated',
    );
  }

  final entries = kexAuthEntriesFromMessage(message);
  final transcript = omemo2KexAuthTranscript(
    senderBareJid: senderBareJid,
    sid: message.senderDeviceId,
    identityKey: senderIk!,
    pqIdentityKey: pqAuth.pqIdentityKey,
    entries: entries,
  );

  final pqOk = PqIdentityStore.verify(
    publicKey: pqAuth.pqIdentityKey,
    message: transcript,
    signature: pqAuth.pqSignature,
  );
  final ikOk = omemo2VerifyIdentitySignature(
    identityKey: senderIk,
    message: transcript,
    signature: pqAuth.ikSignature,
  );
  if (!pqOk || !ikOk) {
    throw PqHandshakeAuthException('invalid <pq-auth> signature');
  }

  final name = senderBareJid.toLowerCase();
  final ikFingerprint = HEX.encode(senderIk).toLowerCase();
  final existing = await pins.pinnedPqIdentity(name, ikFingerprint);
  final nowPinned =
      existing ??
      await pins.pinIfAbsent(name, ikFingerprint, pqAuth.pqIdentityKey);
  if (!_bytesEq(nowPinned, pqAuth.pqIdentityKey)) {
    throw PqIdentityChangedException(name, ikFingerprint);
  }
  return VerifiedHandshake(
    senderName: name,
    ikFingerprint: ikFingerprint,
    pqIdentityKey: pqAuth.pqIdentityKey,
    newlyPinned: existing == null,
  );
}

/// Pin peer `<pq-ik>` before building an outbound session from a bundle.
Future<void> pinPeerPqIdentityFromDevice({
  required PqIdentityPins pins,
  required String bareJid,
  required Uint8List classicalIkSerialized,
  required Uint8List pqIdentityKey,
}) async {
  final ikFingerprint = HEX.encode(classicalIkSerialized).toLowerCase();
  final name = bareJid.toLowerCase();
  final nowPinned = await pins.pinIfAbsent(name, ikFingerprint, pqIdentityKey);
  if (!_bytesEq(nowPinned, pqIdentityKey)) {
    throw PqIdentityChangedException(name, ikFingerprint);
  }
}

bool bytesEqual(List<int> a, List<int> b) => _bytesEq(a, b);

bool _bytesEq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
