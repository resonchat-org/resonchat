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

  /// Registers a bundle without treating it as the announced device list.
  ///
  /// The announced list is what the server published; the bundle map is only
  /// the subset this send resolved. Writing the latter into
  /// [Omemo2Manager.onDeviceListUpdate] is what hid newly announced devices.
  Future<void> registerPeerBundle(PqDevice peer) async {
    final bundle = await peer.toBundle();
    _bundles.putIfAbsent(peer.jid, () => {})[peer.id] = bundle;
  }

  /// Replaces the manager's cached announced list for [jid].
  Future<void> setPeerAnnouncedDeviceIds(String jid, Iterable<int> ids) async {
    await _m.onDeviceListUpdate(jid, ids.toList());
  }

  Future<bool> hasSession(String jid, int deviceId) async {
    final own = _own;
    if (own == null) return false;
    await own.ensureStores();
    return own.sessionStore.containsSession(
      omemo2ProtocolAddress(jid, deviceId),
    );
  }

  Future<void> forgetSession(String jid, int deviceId) async {
    final own = _own;
    if (own == null) return;
    await own.ensureStores();
    await own.sessionStore.deleteSession(omemo2ProtocolAddress(jid, deviceId));
    await onCommit?.call(own);
  }

  Future<void> initiate({required PqDevice own, required PqDevice peer}) async {
    if (_own?.id != own.id) await bindOwn(own);
    await registerPeer(peer);
  }

  Future<Omemo2EncryptionResult> encryptOutgoing({
    required List<String> recipientJids,
    required List<int>? payload,
    Map<String, Set<int>>? recipientDeviceIds,
  }) {
    return _m.onOutgoingStanza(
      Omemo2OutgoingStanza(
        recipientJids: recipientJids,
        payload: payload,
        recipientDeviceIds: recipientDeviceIds,
      ),
    );
  }

  Future<Omemo2DecryptionResult> decryptIncoming(Omemo2IncomingStanza stanza) {
    return _m.onIncomingStanza(stanza);
  }
}
