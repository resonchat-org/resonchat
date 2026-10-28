// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Account chooser for multi-account actions (add contact, join/create room).

import 'package:flutter/material.dart';

import 'package:resonchat/account/account_color.dart';
import 'package:resonchat/account/account_hub.dart';
import 'package:resonchat/l10n/l10n.dart';
import 'package:resonchat/persistence/account_store.dart';
import 'package:resonchat/ui/theme.dart';

/// Enabled accounts that currently have an open session.
List<StoredAccount> accountsReadyForActions() {
  final hub = accountHub;
  return [
    for (final a in hub.accounts)
      if (a.enabled && hub.session(a.id) != null) a,
  ];
}

/// Default account for an action sheet.
///
/// Prefers [preferred] when it is still ready, else the hub primary, else the
/// first ready account.
String? defaultActionAccountId({String? preferred}) {
  final accounts = accountsReadyForActions();
  if (accounts.isEmpty) return null;
  if (preferred != null && accounts.any((a) => a.id == preferred)) {
    return preferred;
  }
  final primary = accountHub.primarySession?.account.id;
  if (primary != null && accounts.any((a) => a.id == primary)) {
    return primary;
  }
  return accounts.first.id;
}

/// Dropdown to pick which account performs an outbound action.
///
/// Hidden when there is at most one ready account — no choice to make.
class AccountActionPicker extends StatelessWidget {
  const AccountActionPicker({
    super.key,
    required this.selectedId,
    required this.onChanged,
    this.accounts,
    this.enabled = true,
  });

  /// Ready accounts; defaults to [accountsReadyForActions].
  final List<StoredAccount>? accounts;

  final String? selectedId;
  final ValueChanged<String> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final list = accounts ?? accountsReadyForActions();
    if (list.length <= 1) return const SizedBox.shrink();
    final l10n = context.l10n;
    final tg = context.tg;
    final value = selectedId != null && list.any((a) => a.id == selectedId)
        ? selectedId
        : list.first.id;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DropdownButtonFormField<String>(
        // ignore: deprecated_member_use — value is the stable API across Flutter SDKs here
        value: value,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: l10n.actionAccount,
          helperText: l10n.actionAccountHint,
        ),
        items: [
          for (final a in list)
            DropdownMenuItem(
              value: a.id,
              child: Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: accountAccent(a.bareJid),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '${a.label} · ${a.bareJid}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: tg.textPrimary, fontSize: 14),
                    ),
                  ),
                ],
              ),
            ),
        ],
        onChanged: enabled
            ? (id) {
                if (id != null) onChanged(id);
              }
            : null,
      ),
    );
  }
}
