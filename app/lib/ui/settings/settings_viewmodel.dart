// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../account/account_hub.dart';
import '../../crypto/omemo/track.dart';
import '../../state/providers.dart';
import '../../xmpp/message_expiry.dart';

/// Privacy preference toggles for Settings.
class SettingsUiState {
  const SettingsUiState({
    this.deliveryReceipts,
    this.readReceipts,
    this.chatStates,
    this.automaticDeletion = AutomaticMessageDeletion.never,
  });

  final bool? deliveryReceipts;
  final bool? readReceipts;
  final bool? chatStates;
  final AutomaticMessageDeletion automaticDeletion;

  SettingsUiState copyWith({
    bool? deliveryReceipts,
    bool? readReceipts,
    bool? chatStates,
    AutomaticMessageDeletion? automaticDeletion,
  }) {
    return SettingsUiState(
      deliveryReceipts: deliveryReceipts ?? this.deliveryReceipts,
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
      final delivery = await db.sendDeliveryReceiptsEnabled();
      final receipts = await db.sendReadReceiptsEnabled();
      final states = await db.sendChatStatesEnabled();
      final deletion = await loadAutomaticMessageDeletion(prefs);
      state = state.copyWith(
        deliveryReceipts: delivery,
        readReceipts: receipts,
        chatStates: states,
        automaticDeletion: deletion,
      );
    });
    return SettingsUiState(
      deliveryReceipts: xmpp.sendDeliveryReceipts,
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

  Future<void> setDeliveryReceipts(bool value) async {
    state = state.copyWith(deliveryReceipts: value);
    // Global privacy toggle — every account / every chat.
    for (final session in accountHub.sessions) {
      session.xmpp.sendDeliveryReceipts = value;
      await session.db.setSendDeliveryReceipts(value);
    }
  }

  Future<void> setReadReceipts(bool value) async {
    state = state.copyWith(readReceipts: value);
    for (final session in accountHub.sessions) {
      session.xmpp.sendReadReceipts = value;
      await session.db.setSendReadReceipts(value);
    }
  }

  Future<void> setChatStates(bool value) async {
    state = state.copyWith(chatStates: value);
    for (final session in accountHub.sessions) {
      session.xmpp.sendTypingNotifications = value;
      await session.db.setSendChatStates(value);
    }
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
