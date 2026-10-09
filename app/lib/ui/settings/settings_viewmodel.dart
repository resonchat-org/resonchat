// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../omemo/track.dart';
import '../../state/providers.dart';

/// Privacy preference toggles for Settings.
class SettingsUiState {
  const SettingsUiState({this.readReceipts, this.chatStates});

  final bool? readReceipts;
  final bool? chatStates;

  SettingsUiState copyWith({bool? readReceipts, bool? chatStates}) {
    return SettingsUiState(
      readReceipts: readReceipts ?? this.readReceipts,
      chatStates: chatStates ?? this.chatStates,
    );
  }
}

class SettingsViewModel extends Notifier<SettingsUiState> {
  @override
  SettingsUiState build() {
    final xmpp = ref.read(xmppServiceProvider);
    Future.microtask(() async {
      final db = ref.read(databaseProvider);
      final receipts = await db.sendReadReceiptsEnabled();
      final states = await db.sendChatStatesEnabled();
      state = state.copyWith(readReceipts: receipts, chatStates: states);
    });
    return SettingsUiState(
      readReceipts: xmpp.sendReadReceipts,
      chatStates: xmpp.sendTypingNotifications,
    );
  }

  Future<void> setGlobalEncryption(Track track) async {
    await ref
        .read(prefsDatabaseProvider)
        .setString('global_track', track.stored);
    ref.invalidate(globalTrackProvider);
  }

  Future<void> setReadReceipts(bool value) async {
    state = state.copyWith(readReceipts: value);
    ref.read(xmppServiceProvider).sendReadReceipts = value;
    await ref.read(databaseProvider).setSendReadReceipts(value);
  }

  Future<void> setChatStates(bool value) async {
    state = state.copyWith(chatStates: value);
    ref.read(xmppServiceProvider).sendTypingNotifications = value;
    await ref.read(databaseProvider).setSendChatStates(value);
  }
}

final settingsViewModelProvider =
    NotifierProvider<SettingsViewModel, SettingsUiState>(SettingsViewModel.new);
