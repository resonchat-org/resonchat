// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// OMEMO2 message layer: thin XML adapter over [Omemo2Manager].

import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:omemo_dart/omemo_dart_omemo2.dart';

import 'package:resonchat/crypto/omemo2/message_codec.dart';
import 'package:resonchat/crypto/omemo2/pq_session.dart';

/// A ready-to-send OMEMO2 `<encrypted>` element.
class PqEncryptedOutgoing {
  const PqEncryptedOutgoing({required this.stanza, required this.deviceId});

  final PqEncryptedMessage stanza;
  final int deviceId;
}

/// Why an OMEMO2 message could not be opened.
class PqDecryptError implements Exception {
  const PqDecryptError(this.reason);
  final String reason;
  @override
  String toString() => 'PqDecryptError: $reason';
}

/// Encrypts and decrypts OMEMO2 messages for one local device.
class PqMessageLayer {
  PqMessageLayer({
    required this.ownDevice,
    required this.sessions,
    required this.senderIkOf,
  });

  final Logger _log = Logger('PqMessageLayer');

  final PqDevice ownDevice;
  final PqSessionManager sessions;

  /// Kept for callers that warm bundle caches; crypto does not need IK bytes.
  final Future<List<int>> Function(String senderBareJid, int deviceId)
  senderIkOf;

  Future<PqEncryptedOutgoing?> encrypt({
    required String plaintext,
    required List<PqDevice> recipients,
  }) async {
    if (recipients.isEmpty) return null;

    await sessions.bindOwn(ownDevice);
    for (final peer in recipients) {
      await sessions.registerPeer(peer);
    }

    final jids = recipients.map((r) => r.jid).toSet().toList();
    final result = await sessions.encryptOutgoing(
      recipientJids: jids,
      payload: utf8.encode(plaintext),
    );
    if (!result.canSend || result.ciphertext == null || result.commit == null) {
      _log.warning('OMEMO2 encrypt incomplete (canSend=${result.canSend})');
      return null;
    }

    final groups = <Omemo2KeysForJid>[];
    for (final e in result.encryptedKeys.entries) {
      groups.add(
        Omemo2KeysForJid(
          jid: e.key,
          keys: [
            for (final k in e.value)
              PqKeyEntry(
                recipientDeviceId: k.rid,
                ciphertext: k.value,
                kex: k.kex,
              ),
          ],
        ),
      );
    }
    if (groups.isEmpty) return null;

    return PqEncryptedOutgoing(
      stanza: PqEncryptedMessage(
        senderDeviceId: ownDevice.id,
        recipients: groups,
        payload: base64Encode(result.ciphertext!),
        commit: base64Encode(result.commit!),
      ),
      deviceId: ownDevice.id,
    );
  }

  Future<String> decrypt(
    PqEncryptedMessage message, {
    required String senderBareJid,
  }) async {
    await sessions.bindOwn(ownDevice);

    try {
      await senderIkOf(senderBareJid, message.senderDeviceId);
    } catch (_) {}

    final result = await sessions.decryptIncoming(
      Omemo2IncomingStanza(
        bareSenderJid: senderBareJid,
        senderDeviceId: message.senderDeviceId,
        recipientBareJid: ownDevice.jid,
        keys: [
          for (final k in message.keys)
            Omemo2EncryptedKey(k.recipientDeviceId, k.ciphertext, k.kex),
        ],
        payload: base64Decode(message.payload),
        commit: base64Decode(message.commit),
      ),
    );

    if (result.error != null || result.payload == null) {
      throw PqDecryptError(result.error?.toString() ?? 'empty plaintext');
    }
    return result.payload!;
  }
}
