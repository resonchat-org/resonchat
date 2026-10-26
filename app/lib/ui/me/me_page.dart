// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Me tab: accounts management. Settings is a list row here; AppBar has none
// (Chats / Contacts keep settings in the top-right).

import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:resonchat/account/account_hub.dart';
import 'package:resonchat/l10n/l10n.dart';
import 'package:resonchat/persistence/account_store.dart';
import 'package:resonchat/state/providers.dart';
import 'package:resonchat/ui/accounts/account_profile_page.dart';
import 'package:resonchat/ui/accounts/remove_account_dialog.dart';
import 'package:resonchat/ui/contact_avatar.dart';
import 'package:resonchat/ui/theme.dart';
import 'package:resonchat/xmpp/connection.dart';

class MePage extends ConsumerWidget {
  const MePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final tg = context.tg;
    final hub = ref.watch(accountHubProvider);

    return ListenableBuilder(
      listenable: hub,
      builder: (context, _) {
        final accounts = hub.accounts;
        return Scaffold(
          appBar: AppBar(title: Text(l10n.tabMe)),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () =>
                Navigator.of(context).pushNamed('/login', arguments: true),
            backgroundColor: tg.accent,
            foregroundColor: Colors.white,
            icon: const Icon(Icons.person_add),
            label: Text(l10n.addAccount),
          ),
          body: accounts.isEmpty
              ? Center(child: Text(l10n.noAccountsYet))
              : ListView(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                      child: Text(
                        l10n.manageAccounts,
                        style: TextStyle(
                          color: tg.textSecondary,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    for (var i = 0; i < accounts.length; i++) ...[
                      if (i > 0) Divider(height: 0.5, color: tg.separator),
                      _AccountTile(account: accounts[i], hub: hub),
                    ],
                    const SizedBox(height: 24),
                    ListTile(
                      leading: Icon(Icons.settings, color: tg.accent),
                      title: Text(l10n.settings),
                      trailing: Icon(
                        Icons.chevron_right,
                        color: tg.textSecondary,
                      ),
                      onTap: () => Navigator.of(context).pushNamed('/settings'),
                    ),
                    const SizedBox(height: 96),
                  ],
                ),
        );
      },
    );
  }
}

class _AccountTile extends StatelessWidget {
  const _AccountTile({required this.account, required this.hub});

  final StoredAccount account;
  final AccountHub hub;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final session = hub.session(account.id);
    final state = session?.xmpp.state ?? XmppConnectionState.disconnected;
    return ListTile(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => AccountProfilePage(accountId: account.id),
        ),
      ),
      onLongPress: () => confirmRemoveAccount(
        context,
        accountId: account.id,
        jid: account.bareJid,
      ),
      leading: ContactAvatar(
        jid: account.bareJid,
        title: account.label,
        radius: 22,
      ),
      title: Text(account.label),
      subtitle: Text(
        '${account.bareJid}\n${_statusLabel(l10n, state, account.enabled)}',
      ),
      isThreeLine: true,
      trailing: Switch(
        value: account.enabled,
        onChanged: (v) => hub.setEnabled(account.id, v),
      ),
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
