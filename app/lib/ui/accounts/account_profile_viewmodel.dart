// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Own nickname, avatar, presence, and device keys for one account. Dialogs
// and snackbars stay on the page; this notifier talks to the session.

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:moxxmpp/moxxmpp.dart' show PresenceShow;

import 'package:resonchat/account/account_hub.dart';
import 'package:resonchat/crypto/dual/fingerprint_trust.dart';
import 'package:resonchat/crypto/dual/own_fingerprints.dart';
import 'package:resonchat/persistence/account_store.dart';
import 'package:resonchat/state/providers.dart';
import 'package:resonchat/xmpp/connection.dart';
import 'package:resonchat/xmpp/roster/avatar.dart';

class AccountProfileUiState {
  const AccountProfileUiState({
    this.busy = false,
    this.deviceId,
    this.hybridFingerprint,
    this.legacyFingerprint,
    this.otherDevices = const [],
    this.avatarPreview,
  });

  final bool busy;
  final int? deviceId;
  final String? hybridFingerprint;
  final String? legacyFingerprint;
  final List<PeerFingerprintRow> otherDevices;
  final Uint8List? avatarPreview;

  AccountProfileUiState copyWith({
    bool? busy,
    int? deviceId,
    String? hybridFingerprint,
    String? legacyFingerprint,
    List<PeerFingerprintRow>? otherDevices,
    Uint8List? avatarPreview,
  }) {
    return AccountProfileUiState(
      busy: busy ?? this.busy,
      deviceId: deviceId ?? this.deviceId,
      hybridFingerprint: hybridFingerprint ?? this.hybridFingerprint,
      legacyFingerprint: legacyFingerprint ?? this.legacyFingerprint,
      otherDevices: otherDevices ?? this.otherDevices,
      avatarPreview: avatarPreview ?? this.avatarPreview,
    );
  }
}

final accountProfileViewModelProvider = NotifierProvider.autoDispose
    .family<AccountProfileViewModel, AccountProfileUiState, String>(
      AccountProfileViewModel.new,
    );

class AccountProfileViewModel
    extends AutoDisposeFamilyNotifier<AccountProfileUiState, String> {
  var _disposed = false;

  @override
  AccountProfileUiState build(String arg) {
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    Future<void>.microtask(load);
    return const AccountProfileUiState();
  }

  AccountSession? get _session => accountHub.session(arg);

  StoredAccount? get account {
    for (final a in accountHub.accounts) {
      if (a.id == arg) return a;
    }
    return null;
  }

  bool get omemoConnected =>
      _session != null && _session!.xmpp.state == XmppConnectionState.connected;

  Future<void> load() async {
    final session = _session;
    if (session == null) return;
    final store = session.xmpp.deviceStore;
    if (store == null) return;
    try {
      final om = session.xmpp.omemo;
      final device = om != null ? await om.getDevice() : await store.load();
      if (device == null) return;
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
      List<PeerFingerprintRow> others = const [];
      try {
        others = await session.xmpp.ownOtherDeviceFingerprintRows();
      } catch (_) {
        // Device list / bundles may be unavailable offline.
      }
      if (_disposed) return;
      state = AccountProfileUiState(
        busy: state.busy,
        avatarPreview: state.avatarPreview,
        deviceId: id,
        hybridFingerprint: (hybridFromTrack?.isNotEmpty ?? false)
            ? hybridFromTrack
            : (fps.hybrid.isEmpty ? null : fps.hybrid),
        legacyFingerprint: fps.legacy,
        otherDevices: others,
      );
    } catch (_) {
      // No device yet.
    }
  }

  Future<bool> saveDisplayName(String name) async {
    state = state.copyWith(busy: true);
    try {
      return await accountHub.setDisplayName(arg, name);
    } finally {
      if (!_disposed) state = state.copyWith(busy: false);
    }
  }

  Future<bool> publishAvatar(Uint8List bytes) async {
    state = state.copyWith(busy: true, avatarPreview: bytes);
    final session = _session;
    final ok = session == null
        ? false
        : await session.xmpp.publishOwnAvatarBytes(bytes);
    if (ok) {
      final prepared = await prepareAvatarImage(bytes);
      final jid = account?.bareJid;
      if (prepared != null && jid != null) {
        seedAvatarCache(jid, prepared.bytes);
        final hash = await prepared.hash;
        final db = _session?.db;
        if (db != null) await noteAvatarChanged(db, jid, hash);
      }
      ref.read(avatarRevisionProvider.notifier).state++;
    }
    if (_disposed) return ok;
    state = state.copyWith(busy: false);
    return ok;
  }

  /// [pq] selects the OMEMO2 identity. Classic regenerate reports success
  /// unless the call throws; OMEMO2 reports the boolean the session returns.
  Future<bool> regenerateKeys({required bool pq}) async {
    final session = _session;
    if (session == null) return false;
    state = state.copyWith(busy: true);
    try {
      final result = pq
          ? await session.xmpp.regenerateOmemo2Keys()
          : await session.xmpp.regenerateOmemoKeys();
      final ok = pq ? result == true : true;
      if (ok) await load();
      return ok;
    } catch (_) {
      return false;
    } finally {
      if (!_disposed) state = state.copyWith(busy: false);
    }
  }

  Future<bool> wipeOtherDevices({required bool pq}) async {
    final session = _session;
    if (session == null) return false;
    state = state.copyWith(busy: true);
    try {
      final ok = pq
          ? await session.xmpp.wipeOtherOmemo2Devices()
          : await session.xmpp.wipeOtherOmemoDevices();
      if (ok) await load();
      return ok;
    } catch (_) {
      return false;
    } finally {
      if (!_disposed) state = state.copyWith(busy: false);
    }
  }

  Future<void> setPresence(PresenceShow show) async {
    final session = _session;
    if (session == null) return;
    await session.xmpp.setOwnPresence(show);
    await session.db.setOwnPresenceShowWire(show.wire ?? 'online');
  }

  /// Gajim AccountOmemoTrustGroup: trust for other devices on our bare JID.
  Future<void> setOtherDeviceTrust(
    PeerFingerprintRow row,
    FingerprintTrust trust,
  ) async {
    final session = _session;
    if (session == null) return;
    await session.xmpp.setPeerFingerprintTrust(
      bareJid: row.peerJid,
      fingerprint: row.fingerprint,
      trust: trust,
    );
    if (_disposed) return;
    state = state.copyWith(
      otherDevices: [
        for (final r in state.otherDevices)
          if (r.fingerprint == row.fingerprint &&
              r.omemo2 == row.omemo2 &&
              r.deviceId == row.deviceId)
            r.copyWith(trust: trust)
          else
            r,
      ],
    );
  }
}
