// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

import 'package:resonchat/account/account_hub.dart';
import 'package:resonchat/net/app_network.dart';
import 'package:resonchat/state/providers.dart';
import 'package:resonchat/xmpp/connect_failure.dart';
import 'package:resonchat/xmpp/connection.dart';

/// Result of [LoginViewModel.connect] (navigation stays in the view).
class LoginResult {
  const LoginResult._({this.failure, this.success = false});

  const LoginResult.ok() : this._(success: true);
  const LoginResult.fail(XmppConnectFailure failure) : this._(failure: failure);

  final bool success;

  /// Why the attempt failed, when it did.
  ///
  /// An enum rather than a message: this layer has no `BuildContext`, and the
  /// sentence a user reads has to be localized. Returning a string from here
  /// is how the login screen ended up printing `Instance of
  /// 'NoConnectionPossibleError'`.
  final XmppConnectFailure? failure;
}

/// Login / add-account commands.
class LoginViewModel extends Notifier<void> {
  final _log = Logger('LoginViewModel');

  @override
  void build() {}

  /// Authenticates and wires session providers. Caller navigates on success.
  Future<LoginResult> connect({
    required String jid,
    required String password,
    String? host,
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
        return LoginResult.fail(
          hub.lastConnectFailure ?? XmppConnectFailure.unknown,
        );
      }
      if (hub.primarySession == null) {
        return LoginResult.fail(XmppConnectFailure.unknown);
      }

      ref.read(connectionStateProvider.notifier).state =
          XmppConnectionState.connected;
      ref.invalidate(databaseProvider);
      ref.invalidate(xmppServiceProvider);
      ref.read(selectedChatKeyProvider.notifier).state = null;
      return const LoginResult.ok();
    } catch (e, stack) {
      // A throw that reached here is by definition not one of the failures we
      // can name, so it is reported as exactly that. The detail goes to the
      // log for a bug report; the user is not shown a Dart exception.
      _log.severe('login threw', e, stack);
      return LoginResult.fail(XmppConnectFailure.unknown);
    }
  }
}

final loginViewModelProvider = NotifierProvider<LoginViewModel, void>(
  LoginViewModel.new,
);
