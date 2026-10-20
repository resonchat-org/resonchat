// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Conversations `XmppActivity.deleteAccount`: removing the account from this
// device, with an extra checkbox to unregister it on the server (XEP-0077).

import 'package:flutter/material.dart';

import 'package:resonchat/account/account_hub.dart';
import 'package:resonchat/l10n/l10n.dart';
import 'package:resonchat/xmpp/connection.dart';

/// Confirms removal. The server checkbox is available only while connected.
Future<void> confirmRemoveAccount(
  BuildContext context, {
  required String accountId,
  required String jid,
}) async {
  final l10n = context.l10n;
  final connected =
      accountHub.session(accountId)?.xmpp.state ==
      XmppConnectionState.connected;
  var unregister = false;
  final choice = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => AlertDialog(
        title: Text(l10n.removeAccount),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l10n.removeAccountConfirm(jid)),
            const SizedBox(height: 12),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: unregister,
              onChanged: connected
                  ? (v) => setLocal(() => unregister = v ?? false)
                  : null,
              title: Text(l10n.unregisterAccountOnServer),
              subtitle: connected
                  ? null
                  : Text(l10n.unregisterAccountNeedsConnection),
              controlAffinity: ListTileControlAffinity.leading,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.removeAccount),
          ),
        ],
      ),
    ),
  );
  if (choice != true || !context.mounted) return;
  final ok = await accountHub.removeAccount(
    accountId,
    unregisterOnServer: unregister,
  );
  if (!context.mounted) return;
  if (!ok) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(l10n.couldNotUnregisterAccount)));
  }
}
