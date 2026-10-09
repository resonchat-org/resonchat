// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../crypto/omemo/track.dart';
import '../../state/providers.dart';
import '../../xmpp/message_expiry.dart';

/// Privacy preference toggles for Settings.
class SettingsUiState {
  const SettingsUiState({
    this.readReceipts,
    this.chatStates,
    this.automaticDeletion = AutomaticMessageDeletion.never,
  });

  final bool? readReceipts;
  final bool? chatStates;
  final AutomaticMessageDeletion automaticDeletion;

  SettingsUiState copyWith({
    bool? readReceipts,
    bool? chatStates,
    AutomaticMessageDeletion? automaticDeletion,
  }) {
    return SettingsUiState(
      readReceipts: readReceipts ?? this.readReceipts,
      chatStates: chatStates ?? this.chatStates,
      automaticDeletion: automaticDeletion ?? this.automaticDeletion,
    );
  }
}

class SettingsViewModel extends Notifier<SettingsUiState> {
  @override
  SettingsUiState build() {
    final xmpp = ref.read(xmppServiceProvider);
    Future.microtask(() async {
      final db = ref.read(databaseProvider);
      final prefs = ref.read(prefsDatabaseProvider);
      final receipts = await db.sendReadReceiptsEnabled();
      final states = await db.sendChatStatesEnabled();
      final deletion = await loadAutomaticMessageDeletion(prefs);
      state = state.copyWith(
        readReceipts: receipts,
        chatStates: states,
        automaticDeletion: deletion,
      );
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

  /// Conversations-style global retention; sweeps immediately on change.
  Future<void> setAutomaticMessageDeletion(
    AutomaticMessageDeletion value,
  ) async {
    state = state.copyWith(automaticDeletion: value);
    await saveAutomaticMessageDeletion(
      value,
      prefs: ref.read(prefsDatabaseProvider),
    );
    await expireOldMessagesAcrossAccounts(setting: value);
  }
}

final settingsViewModelProvider =
    NotifierProvider<SettingsViewModel, SettingsUiState>(SettingsViewModel.new);
