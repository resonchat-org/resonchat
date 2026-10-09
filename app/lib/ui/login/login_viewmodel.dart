// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../account/account_hub.dart';
import '../../net/app_network.dart';
import '../../state/providers.dart';
import '../../xmpp/connection.dart';

/// Result of [LoginViewModel.connect] (navigation stays in the view).
class LoginResult {
  const LoginResult._({this.error, this.success = false});

  const LoginResult.ok() : this._(success: true);
  const LoginResult.fail(String error) : this._(error: error);

  final bool success;
  final String? error;
}

/// Login / add-account commands.
class LoginViewModel extends Notifier<void> {
  @override
  void build() {}

  /// Authenticates and wires session providers. Caller navigates on success.
  Future<LoginResult> connect({
    required String jid,
    required String password,
    String? host,
    required String authFailedLabel,
  }) async {
    try {
      await appNetwork.waitUntilReady();
      final hub = accountHub;
      final ok = await hub.addAndConnect(
        jid: jid.trim(),
        password: password,
        host: host == null || host.trim().isEmpty ? null : host.trim(),
      );
      if (!ok) {
        return LoginResult.fail(hub.lastConnectError ?? authFailedLabel);
      }
      if (hub.primarySession == null) {
        return LoginResult.fail(authFailedLabel);
      }

      ref.read(connectionStateProvider.notifier).state =
          XmppConnectionState.connected;
      ref.invalidate(databaseProvider);
      ref.invalidate(xmppServiceProvider);
      ref.read(selectedChatKeyProvider.notifier).state = null;
      return const LoginResult.ok();
    } catch (e) {
      return LoginResult.fail('$e');
    }
  }
}

final loginViewModelProvider = NotifierProvider<LoginViewModel, void>(
  LoginViewModel.new,
);
