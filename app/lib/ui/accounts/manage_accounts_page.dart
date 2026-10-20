// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Conversations ManageAccountActivity: list accounts, enable/disable, add.

import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:resonchat/l10n/l10n.dart';
import 'package:resonchat/state/providers.dart';
import 'package:resonchat/ui/accounts/account_profile_page.dart';
import 'package:resonchat/ui/accounts/remove_account_dialog.dart';
import 'package:resonchat/ui/contact_avatar.dart';
import 'package:resonchat/ui/theme.dart';
import 'package:resonchat/xmpp/connection.dart';

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
                    return ListTile(
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => AccountProfilePage(accountId: a.id),
                        ),
                      ),
                      onLongPress: () => confirmRemoveAccount(
                        context,
                        accountId: a.id,
                        jid: a.bareJid,
                      ),
                      leading: ContactAvatar(
                        jid: a.bareJid,
                        title: a.label,
                        radius: 22,
                      ),
                      title: Text(a.label),
                      subtitle: Text(
                        '${a.bareJid}\n${_statusLabel(l10n, state, a.enabled)}',
                      ),
                      isThreeLine: true,
                      trailing: Switch(
                        value: a.enabled,
                        onChanged: (v) async {
                          await hub.setEnabled(a.id, v);
                          if (!context.mounted) return;
                          // Cold-start lander is `/accounts` when every account
                          // was disabled — enter the chat shell after re-enable.
                          if (v && hub.hasEnabledAccounts) {
                            Navigator.of(context)
                                .pushReplacementNamed('/chats');
                          }
                        },
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
}
