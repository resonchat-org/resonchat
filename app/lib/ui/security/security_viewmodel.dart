// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Fingerprints and per-device trust for one chat. The page only draws this
// state and copies text to the clipboard.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:resonchat/account/resolve.dart';
import 'package:resonchat/crypto/dual/fingerprint_trust.dart';
import 'package:resonchat/crypto/dual/own_fingerprints.dart';
import 'package:resonchat/state/providers.dart';

/// Loaded encryption page for one chat ([ChatRef.key] or a legacy bare JID).
class SecurityUiState {
  const SecurityUiState({
    this.deviceId,
    this.hybridFingerprint,
    this.legacyFingerprint,
    this.peerRows,
    this.peerLoading = true,
    this.peerRefreshing = false,
    this.peerError,
    this.isGroup = false,
  });

  final int? deviceId;
  final String? hybridFingerprint;
  final String? legacyFingerprint;
  final List<PeerFingerprintRow>? peerRows;
  final bool peerLoading;

  /// Network refresh in flight after local rows were already shown.
  final bool peerRefreshing;
  final String? peerError;
  final bool isGroup;

  SecurityUiState copyWith({
    List<PeerFingerprintRow>? peerRows,
    bool? peerLoading,
    bool? peerRefreshing,
    String? peerError,
    bool clearPeerError = false,
  }) {
    return SecurityUiState(
      deviceId: deviceId,
      hybridFingerprint: hybridFingerprint,
      legacyFingerprint: legacyFingerprint,
      peerRows: peerRows ?? this.peerRows,
      peerLoading: peerLoading ?? this.peerLoading,
      peerRefreshing: peerRefreshing ?? this.peerRefreshing,
      peerError: clearPeerError ? null : (peerError ?? this.peerError),
      isGroup: isGroup,
    );
  }
}

final securityViewModelProvider = NotifierProvider.autoDispose
    .family<SecurityViewModel, SecurityUiState, String>(SecurityViewModel.new);

class SecurityViewModel
    extends AutoDisposeFamilyNotifier<SecurityUiState, String> {
  var _disposed = false;

  @override
  SecurityUiState build(String arg) {
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    Future<void>.microtask(load);
    return const SecurityUiState();
  }

  String get _peerBare => resolveChatKey(arg).jid;

  Future<void> load() async {
    final session = resolveChatKey(arg).session;
    final store = session.xmpp.deviceStore;
    final om = session.xmpp.omemo;
    if (store == null || om == null) {
      state = const SecurityUiState(peerLoading: false);
      return;
    }
    final device = await om.getDevice();
    final id = await device.deviceId;
    final hybridFromTrack = await session.xmpp.bTrack?.hybridFingerprint();
    List<int>? omemo2Ik;
    final bDev = session.xmpp.bTrack?.device;
    if (bDev != null) {
      omemo2Ik = await bDev.identityPublicSerialized();
    }
    final fps = await loadOwnFingerprints(
      legacyDevice: device,
      pqStore: store.pqIdentity,
      omemo2IkSerialized: omemo2Ik,
    );
    final chat = await session.db.getChat(_peerBare);
    final isGroup = chat?.isGroup ?? false;

    // 1) Local identities immediately — do not block the spinner on PEP.
    List<PeerFingerprintRow> localPeers = const [];
    try {
      if (isGroup) {
        final room = await ref.read(roomStateProvider(arg).future);
        final ownBare = session.xmpp.myJid?.toLowerCase();
        final members = <String>{
          for (final o in room?.occupants ?? const [])
            if (o.realJid != null &&
                o.realJid!.isNotEmpty &&
                o.realJid!.toLowerCase() != ownBare)
              o.realJid!,
        };
        localPeers = await session.xmpp.groupFingerprintRows(
          members,
          refreshFromNetwork: false,
        );
      } else {
        localPeers = await session.xmpp.peerFingerprintRowsLocal(_peerBare);
      }
    } catch (_) {
      // Empty local list is fine; refresh may still fill it.
    }
    if (_disposed) return;
    state = SecurityUiState(
      deviceId: id,
      isGroup: isGroup,
      hybridFingerprint: (hybridFromTrack?.isNotEmpty ?? false)
          ? hybridFromTrack
          : (fps.hybrid.isEmpty ? null : fps.hybrid),
      legacyFingerprint: fps.legacy,
      peerRows: localPeers,
      peerLoading: false,
      peerRefreshing: true,
    );

    // 2) Background PEP refresh; update the list when it finishes.
    try {
      final List<PeerFingerprintRow> refreshed;
      if (isGroup) {
        final room = await ref.read(roomStateProvider(arg).future);
        final ownBare = session.xmpp.myJid?.toLowerCase();
        final members = <String>{
          for (final o in room?.occupants ?? const [])
            if (o.realJid != null &&
                o.realJid!.isNotEmpty &&
                o.realJid!.toLowerCase() != ownBare)
              o.realJid!,
        };
        refreshed = await session.xmpp.groupFingerprintRows(members);
      } else {
        refreshed = await session.xmpp.peerFingerprintRows(_peerBare);
      }
      if (_disposed) return;
      state = state.copyWith(
        peerRows: refreshed,
        peerRefreshing: false,
        clearPeerError: true,
      );
    } catch (e) {
      if (_disposed) return;
      state = state.copyWith(peerRefreshing: false, peerError: e.toString());
    }
  }

  Future<void> setPeerTrust(
    PeerFingerprintRow row,
    FingerprintTrust trust,
  ) async {
    final xmpp = resolveChatKey(arg).session.xmpp;
    await xmpp.setPeerFingerprintTrust(
      bareJid: row.peerJid,
      fingerprint: row.fingerprint,
      trust: trust,
    );
    if (_disposed) return;
    final rows = state.peerRows;
    if (rows == null) return;
    state = state.copyWith(
      peerRows: [
        for (final r in rows)
          if (r.fingerprint == row.fingerprint &&
              r.omemo2 == row.omemo2 &&
              r.peerJid == row.peerJid)
            PeerFingerprintRow(
              peerJid: r.peerJid,
              deviceId: r.deviceId,
              fingerprint: r.fingerprint,
              omemo2: r.omemo2,
              trust: trust,
              active: r.active,
            )
          else
            r,
      ],
    );
  }
}
