// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:moxxmpp/moxxmpp.dart';

import '../../account/resolve.dart';

/// MUC owner config form I/O (field editing stays in the view).
class RoomConfigViewModel extends Notifier<void> {
  @override
  void build() {}

  Future<DataForm?> fetchForm(String chatKey, {String? lang}) {
    final r = resolveChatKey(chatKey);
    return r.session.xmpp.fetchRoomConfigForm(r.jid, lang: lang);
  }

  Future<bool> submitForm(String chatKey, DataForm form) {
    final r = resolveChatKey(chatKey);
    return r.session.xmpp.submitRoomConfigForm(r.jid, form);
  }

  Future<void> cancelForm(String chatKey) {
    final r = resolveChatKey(chatKey);
    return r.session.xmpp.cancelRoomConfigForm(r.jid);
  }
}

final roomConfigViewModelProvider = NotifierProvider<RoomConfigViewModel, void>(
  RoomConfigViewModel.new,
);
