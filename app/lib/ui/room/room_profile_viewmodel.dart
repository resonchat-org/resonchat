// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Room title, description, subject, and avatar. The page owns the edit
// dialogs and pops navigation results.

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:resonchat/account/resolve.dart';
import 'package:resonchat/state/providers.dart';
import 'package:resonchat/xmpp/muc/muc.dart';
import 'package:resonchat/xmpp/roster/avatar.dart';

const Object _keep = Object();

class RoomProfileUiState {
  const RoomProfileUiState({
    this.caps,
    this.loadingCaps = true,
    this.roomTitle,
    this.description,
    this.editedSubject,
    this.avatarPreview,
    this.avatarBusy = false,
  });

  final RoomSelfCapabilities? caps;
  final bool loadingCaps;
  final String? roomTitle;
  final String? description;
  final String? editedSubject;
  final Uint8List? avatarPreview;
  final bool avatarBusy;

  RoomProfileUiState copyWith({
    RoomSelfCapabilities? caps,
    bool? loadingCaps,
    Object? roomTitle = _keep,
    Object? description = _keep,
    Object? editedSubject = _keep,
    Object? avatarPreview = _keep,
    bool? avatarBusy,
  }) {
    return RoomProfileUiState(
      caps: caps ?? this.caps,
      loadingCaps: loadingCaps ?? this.loadingCaps,
      roomTitle: identical(roomTitle, _keep)
          ? this.roomTitle
          : roomTitle as String?,
      description: identical(description, _keep)
          ? this.description
          : description as String?,
      editedSubject: identical(editedSubject, _keep)
          ? this.editedSubject
          : editedSubject as String?,
      avatarPreview: identical(avatarPreview, _keep)
          ? this.avatarPreview
          : avatarPreview as Uint8List?,
      avatarBusy: avatarBusy ?? this.avatarBusy,
    );
  }
}

final roomProfileViewModelProvider = NotifierProvider.autoDispose
    .family<RoomProfileViewModel, RoomProfileUiState, String>(
      RoomProfileViewModel.new,
    );

class RoomProfileViewModel
    extends AutoDisposeFamilyNotifier<RoomProfileUiState, String> {
  var _disposed = false;

  @override
  RoomProfileUiState build(String arg) {
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    Future<void>.microtask(load);
    return const RoomProfileUiState();
  }

  String get roomJid => resolveChatKey(arg).jid;

  Future<void> load() async {
    final xmpp = resolveChatKey(arg).session.xmpp;
    final caps = await xmpp.roomSelfCapabilities(roomJid);
    if (_disposed) return;
    state = state.copyWith(caps: caps, loadingCaps: false);
    final chat = ref.read(chatProvider(arg)).value;
    final title = chat?.title.trim();
    if (title != null && title.isNotEmpty && title != roomJid) {
      state = state.copyWith(roomTitle: title);
    }
    final desc = await xmpp.queryRoomDescription(roomJid);
    if (_disposed) return;
    state = state.copyWith(description: desc);
  }

  Future<bool> saveRoomName(String trimmed) async {
    final xmpp = resolveChatKey(arg).session.xmpp;
    final ok = await xmpp.setRoomName(roomJid, trimmed);
    if (!ok) return false;
    final db = resolveChatKey(arg).session.db;
    await db.upsertChat(
      roomJid,
      isGroup: true,
      title: trimmed.isEmpty ? roomJid : trimmed,
    );
    if (_disposed) return true;
    state = state.copyWith(roomTitle: trimmed.isEmpty ? null : trimmed);
    ref.invalidate(chatProvider(arg));
    return true;
  }

  Future<bool> publishAvatar(Uint8List bytes) async {
    state = state.copyWith(avatarBusy: true, avatarPreview: bytes);
    final ok = await resolveChatKey(arg).session.xmpp
        .publishMucAvatar(roomJid, bytes);
    if (ok) {
      final prepared = await prepareAvatarImage(bytes);
      if (prepared != null) {
        seedAvatarCache(roomJid, prepared.bytes);
        ref.read(avatarRevisionProvider.notifier).state++;
      }
    }
    if (_disposed) return ok;
    state = state.copyWith(avatarBusy: false);
    return ok;
  }

  Future<bool> saveDescription(String trimmed) async {
    final ok = await resolveChatKey(arg).session.xmpp
        .setRoomDescription(roomJid, trimmed);
    if (!ok) return false;
    if (_disposed) return true;
    state = state.copyWith(description: trimmed.isEmpty ? null : trimmed);
    return true;
  }

  Future<void> saveSubject(String trimmed) async {
    await resolveChatKey(arg).session.xmpp
        .setGroupChatSubject(roomJid, trimmed);
    if (_disposed) return;
    state = state.copyWith(editedSubject: trimmed);
  }
}
