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
  PqMessageLayer({required this.ownDevice, required this.sessions});

  final Logger _log = Logger('PqMessageLayer');

  final PqDevice ownDevice;
  final PqSessionManager sessions;

  /// Encrypts [plaintext].
  ///
  /// Legacy callers pass [recipients] and leave [recipientDeviceIds] null; the
  /// manager then uses its announced list as before.
  ///
  /// Sending code passes [requestedJids] (the original target set, already
  /// normalized to bare JIDs), the full [announcedDeviceIds], and the
  /// [recipientDeviceIds] allow-list. Every requested JID must have an entry
  /// in the allow-list, including an empty one for an explicitly excluded
  /// member. Only non-empty entries become actual vendor recipients; an empty
  /// entry is reported but never handed to the manager as a target.
  Future<PqEncryptedOutgoing?> encrypt({
    required String plaintext,
    List<PqDevice> recipients = const [],
    List<String>? requestedJids,
    Map<String, Set<int>>? announcedDeviceIds,
    Map<String, Set<int>>? recipientDeviceIds,
  }) async {
    await sessions.bindOwn(ownDevice);

    if (recipientDeviceIds == null) {
      if (recipients.isEmpty) return null;
      for (final peer in recipients) {
        await sessions.registerPeer(peer);
      }
      final jids = recipients.map((r) => r.jid).toSet().toList();
      final result = await sessions.encryptOutgoing(
        recipientJids: jids,
        payload: utf8.encode(plaintext),
      );
      return _buildOutgoing(result);
    }

    final requested = requestedJids ?? const <String>[];
    if (requested.isEmpty) {
      _log.warning('OMEMO2 strict send without requestedJids');
      return null;
    }

    // The request set is authoritative. A missing key here would let a caller
    // omit a recipient from both the allow-list and the vendor stanza.
    for (final jid in requested) {
      if (!recipientDeviceIds.containsKey(jid)) {
        _log.warning('OMEMO2 strict send missing allow-list for $jid');
        return null;
      }
    }
    if (announcedDeviceIds != null) {
      for (final jid in requested) {
        if (!announcedDeviceIds.containsKey(jid)) {
          _log.warning('OMEMO2 strict send missing announced list for $jid');
          return null;
        }
      }
    }

    // A recipient device can only be registered if its JID is in the map.
    for (final peer in recipients) {
      if (!recipientDeviceIds.containsKey(peer.jid)) {
        _log.warning('OMEMO2 strict send missing allow-list for ${peer.jid}');
        return null;
      }
    }

    if (announcedDeviceIds != null) {
      for (final entry in announcedDeviceIds.entries) {
        await sessions.setPeerAnnouncedDeviceIds(entry.key, entry.value);
      }
    }
    for (final peer in recipients) {
      await sessions.registerPeerBundle(peer);
    }

    final actualJids = <String>[
      for (final jid in requested)
        if (recipientDeviceIds[jid]!.isNotEmpty) jid,
    ];
    if (actualJids.isEmpty) {
      _log.warning('OMEMO2 strict send has no actual encryption targets');
      return null;
    }

    final result = await sessions.encryptOutgoing(
      recipientJids: actualJids,
      payload: utf8.encode(plaintext),
      recipientDeviceIds: recipientDeviceIds,
    );
    return _buildOutgoing(result);
  }

  PqEncryptedOutgoing? _buildOutgoing(Omemo2EncryptionResult result) {
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
