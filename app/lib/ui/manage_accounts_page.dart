// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Conversations ManageAccountActivity: list accounts, enable/disable, add.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../account/account_color.dart';
import '../account/account_hub.dart';
import '../l10n/l10n.dart';
import '../state/providers.dart';
import '../xmpp/connection.dart';
import 'theme.dart';

class ManageAccountsPage extends ConsumerWidget {
  const ManageAccountsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final tg = context.tg;
    final hub = ref.watch(accountHubProvider);
    // Rebuild when hub notifies.
    return ListenableBuilder(
      listenable: hub,
      builder: (context, _) {
        final accounts = hub.accounts;
        return Scaffold(
          appBar: AppBar(title: Text(l10n.manageAccounts)),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => Navigator.of(context).pushNamed(
              '/login',
              arguments: true, // add-account mode
            ),
            backgroundColor: tg.accent,
            foregroundColor: Colors.white,
            icon: const Icon(Icons.person_add),
            label: Text(l10n.addAccount),
          ),
          body: accounts.isEmpty
              ? Center(child: Text(l10n.noAccountsYet))
              : ListView.separated(
                  itemCount: accounts.length,
                  separatorBuilder: (_, _) =>
                      Divider(height: 0.5, color: tg.separator),
                  itemBuilder: (context, i) {
                    final a = accounts[i];
                    final session = hub.session(a.id);
                    final state =
                        session?.xmpp.state ?? XmppConnectionState.disconnected;
                    final accent = accountAccent(a.bareJid);
                    return ListTile(
                      onLongPress: () =>
                          _confirmRemove(context, hub, a.id, a.bareJid),
                      leading: CircleAvatar(
                        backgroundColor: accent.withValues(alpha: 0.2),
                        child: Text(
                          a.bareJid.isEmpty ? '?' : a.bareJid[0].toUpperCase(),
                          style: TextStyle(
                            color: accent,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      title: Text(a.bareJid),
                      subtitle: Text(_statusLabel(l10n, state, a.enabled)),
                      trailing: Switch(
                        value: a.enabled,
                        onChanged: (v) => hub.setEnabled(a.id, v),
                      ),
                    );
                  },
                ),
        );
      },
    );
  }

  String _statusLabel(
    AppLocalizations l10n,
    XmppConnectionState state,
    bool enabled,
  ) {
    if (!enabled) return l10n.accountDisabled;
    return switch (state) {
      XmppConnectionState.connected => l10n.statusConnected,
      XmppConnectionState.connecting => l10n.statusConnecting,
      XmppConnectionState.disconnected => l10n.statusDisconnected,
    };
  }

  Future<void> _confirmRemove(
    BuildContext context,
    AccountHub hub,
    String id,
    String jid,
  ) async {
    final l10n = context.l10n;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.removeAccount),
        content: Text(l10n.removeAccountConfirm(jid)),
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
    );
    if (ok == true) await hub.removeAccount(id);
  }
}
