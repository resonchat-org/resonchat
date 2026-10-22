// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// B-track device + session facade over omemo_dart [Omemo2Manager].

import 'package:omemo_dart/omemo_dart_omemo2.dart';

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
  PqSessionManager({this.onCommit});

  /// Persists the device, including session records, after encrypt/decrypt.
  ///
  /// Conversations writes the session before the stanza leaves. Wiping the
  /// sealed blob (regenerate) is what drops them.
  final Future<void> Function(PqDevice device)? onCommit;

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
    final commit = onCommit;
    _manager = Omemo2Manager(
      own,
      fetchDeviceList: (jid) async {
        final map = _bundles[jid];
        if (map == null || map.isEmpty) return null;
        return map.keys.toList();
      },
      fetchBundle: (jid, deviceId) async => _bundles[jid]?[deviceId],
      commitDevice: commit ?? (_) async {},
    );
  }

  Future<void> registerPeer(PqDevice peer) async {
    final bundle = await peer.toBundle();
    _bundles.putIfAbsent(peer.jid, () => {})[peer.id] = bundle;
    await _m.onDeviceListUpdate(peer.jid, _bundles[peer.jid]!.keys.toList());
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
}
