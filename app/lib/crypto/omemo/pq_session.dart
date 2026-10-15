// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// B-track device + session facade over omemo_dart [Omemo2Manager].

import 'dart:typed_data';

import 'package:libsignal/libsignal.dart' as ls;
import 'package:omemo_dart/omemo_dart_omemo2.dart';

import '../pq/mlkem.dart';

/// App alias for the OMEMO2 device (kept for existing call sites).
typedef PqDevice = Omemo2Device;

class PqSessionError implements Exception {
  const PqSessionError(this.message);
  final String message;
  @override
  String toString() => 'PqSessionError: $message';
}

/// Registers peer bundles in-memory and drives [Omemo2Manager].
class PqSessionManager {
  PqSessionManager({required this.kem});

  /// Retained for API compatibility; KEM is native libsignal inside Omemo2Device.
  final MlKem1024 kem;

  Omemo2Manager? _manager;
  Omemo2Device? _own;
  final Map<String, Map<int, Omemo2PreKeyBundle>> _bundles = {};

  Omemo2Manager get _m {
    final m = _manager;
    if (m == null) {
      throw const PqSessionError('session manager not bound to a local device');
    }
    return m;
  }

  Future<void> bindOwn(PqDevice own) async {
    if (_own?.id == own.id && _manager != null) return;
    _own = own;
    await own.ensureStores();
    _manager = Omemo2Manager(
      own,
      fetchDeviceList: (jid) async {
        final map = _bundles[jid];
        if (map == null || map.isEmpty) return null;
        return map.keys.toList();
      },
      fetchBundle: (jid, deviceId) async => _bundles[jid]?[deviceId],
    );
  }

  Future<void> registerPeer(PqDevice peer) async {
    final bundle = await peer.toBundle();
    _bundles.putIfAbsent(peer.jid, () => {})[peer.id] = bundle;
    await _m.onDeviceListUpdate(peer.jid, _bundles[peer.jid]!.keys.toList());
  }

  Future<bool> hasSession(String jid, int deviceId) async {
    final own = _own;
    if (own == null) return false;
    await own.ensureStores();
    return own.sessionStore.containsSession(
      omemo2ProtocolAddress(jid, deviceId),
    );
  }

  Future<void> initiate({required PqDevice own, required PqDevice peer}) async {
    if (_own?.id != own.id) await bindOwn(own);
    await registerPeer(peer);
  }

  Future<Omemo2EncryptionResult> encryptOutgoing({
    required List<String> recipientJids,
    required List<int>? payload,
  }) {
    return _m.onOutgoingStanza(
      Omemo2OutgoingStanza(recipientJids: recipientJids, payload: payload),
    );
  }

  Future<Omemo2DecryptionResult> decryptIncoming(Omemo2IncomingStanza stanza) {
    return _m.onIncomingStanza(stanza);
  }

  /// SessionCipher-wrap a bare message key (prekey-pool / unit tests).
  Future<PqSessionCiphertext> encryptMessageKey({
    required PqDevice own,
    required PqDevice peer,
    required Uint8List messageKey,
  }) async {
    await initiate(own: own, peer: peer);
    await own.ensureStores();
    final addr = omemo2ProtocolAddress(peer.jid, peer.id);
    if (!await own.sessionStore.containsSession(addr)) {
      await _processBundle(own, await peer.toBundle());
    }
    final encrypted = await own.sessionCipher().encrypt(addr, messageKey);
    return PqSessionCiphertext(
      bytes: encrypted.ciphertext,
      isPreKey: encrypted.isPreKeyMessage,
    );
  }

  Future<Uint8List> decryptMessageKey({
    required String senderJid,
    required int senderDeviceId,
    required Uint8List serialized,
    required bool isPreKey,
  }) async {
    final own = _own;
    if (own == null) {
      throw const PqSessionError('session manager not bound to a local device');
    }
    await own.ensureStores();
    final type = isPreKey
        ? ls.CiphertextMessageType.preKey
        : ls.CiphertextMessageType.signal;
    final ct = ls.CiphertextMessage(type: type, ciphertext: serialized);
    return own.sessionCipher().decrypt(
      omemo2ProtocolAddress(senderJid, senderDeviceId),
      ct,
    );
  }

  Future<void> forget(String jid, int deviceId) async {
    final own = _own;
    if (own == null) return;
    await own.ensureStores();
    await own.sessionStore.deleteSession(omemo2ProtocolAddress(jid, deviceId));
  }

  Future<void> forgetAll() async {
    final own = _own;
    if (own == null) return;
    _manager = null;
    await bindOwn(own);
  }

  Future<void> _processBundle(
    Omemo2Device own,
    Omemo2PreKeyBundle bundle,
  ) async {
    var preKeyBundle = ls.PreKeyBundle(
      registrationId: 0,
      deviceId: 1,
      preKeyId: bundle.preKeyId,
      preKeyPublic: bundle.preKeyPublicTagged,
      signedPreKeyId: bundle.signedPreKeyId,
      signedPreKeyPublic: bundle.signedPreKeyPublicTagged,
      signedPreKeySignature: bundle.signedPreKeySignature,
      identityKey: bundle.identityPublicTagged,
      kyberPreKeyId: bundle.kyberPreKeyId,
      kyberPreKeyPublic: bundle.kyberPreKeyPublicTagged,
      kyberPreKeySignature: bundle.kyberPreKeySignature,
    );
    if (bundle.hasPqIdentity) {
      final kemBinding = ls.pqKemBinding(
        kemSignedPreKeyId: bundle.kemSignedPreKeyId,
        kemSignedPreKeyPublic: bundle.kemSignedPreKeyPublicTagged,
        oneTime: [
          for (final k in bundle.kemOneTimeKeys)
            ls.KemOneTimeKey(id: k.id, publicKey: k.publicTagged),
        ],
      );
      preKeyBundle = preKeyBundle.withPqIdentity(
        pqIdentityKey: bundle.pqIdentityKey!,
        pqSignature: bundle.pqSignature!,
        kemBinding: kemBinding,
      );
    }
    final builder = ls.SessionBuilder(
      localAddress: own.localAddress,
      sessionStore: own.sessionStore,
      identityKeyStore: own.identityStore,
    );
    await builder.processPreKeyBundle(
      omemo2ProtocolAddress(bundle.jid, bundle.deviceId),
      preKeyBundle,
    );
  }
}

/// Ciphertext wrapper for SessionCipher-only helpers / tests.
class PqSessionCiphertext {
  const PqSessionCiphertext({required this.bytes, required this.isPreKey});
  final Uint8List bytes;
  final bool isPreKey;
  Uint8List serialize() => bytes;
}
