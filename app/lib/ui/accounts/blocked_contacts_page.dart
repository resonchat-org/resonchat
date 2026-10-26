// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Per-account block list (XEP-0191).

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:resonchat/account/account_hub.dart';
import 'package:resonchat/l10n/l10n.dart';
import 'package:resonchat/state/providers.dart';
import 'package:resonchat/ui/ban_list.dart';
import 'package:resonchat/ui/theme.dart';
import 'package:resonchat/xmpp/roster/blocking.dart';

class BlockedContactsPage extends ConsumerStatefulWidget {
  const BlockedContactsPage({super.key, required this.accountId});

  final String accountId;

  @override
  ConsumerState<BlockedContactsPage> createState() =>
      _BlockedContactsPageState();
}

class _BlockedContactsPageState extends ConsumerState<BlockedContactsPage> {
  bool _syncing = false;

  AccountSession? get _session => accountHub.session(widget.accountId);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_syncFromServer());
    });
  }

  Future<void> _bump() async {
    final s = _session;
    if (s != null) s.xmpp.blockedJids = await s.db.blockedJids();
    ref.read(blockRevisionProvider.notifier).state++;
  }

  Future<void> _syncFromServer() async {
    final s = _session;
    if (s == null) return;
    setState(() => _syncing = true);
    try {
      await mergeServerBlocklist(s.xmpp, s.db);
      await _bump();
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _add() async {
    final l10n = context.l10n;
    final s = _session;
    if (s == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.notConnectedTryAgain)));
      return;
    }
    final result = await showAddBanJidDialog(
      context,
      title: l10n.addBlockedContact,
      confirmLabel: l10n.block,
    );
    if (result == null || !mounted) return;
    await blockContact(s.xmpp, s.db, result.jid);
    await _bump();
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.contactBlocked)));
    }
  }

  Future<void> _remove(String jid) async {
    final l10n = context.l10n;
    final s = _session;
    if (s == null) return;
    await unblockContact(s.xmpp, s.db, jid);
    await _bump();
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.contactUnblocked)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final tg = context.tg;
    final l10n = context.l10n;
    final account = accountHub.accounts
        .where((a) => a.id == widget.accountId)
        .firstOrNull;
    final async = ref.watch(blockedJidsProvider(widget.accountId));

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.blockedContacts),
        actions: [
          if (_syncing)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              tooltip: l10n.refresh,
              onPressed: () => unawaited(_syncFromServer()),
              icon: const Icon(Icons.refresh),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => unawaited(_add()),
        tooltip: l10n.addBlockedContact,
        child: const Icon(Icons.person_add_disabled_outlined),
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (set) {
          final list = set.toList()..sort();
          if (list.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  l10n.blockedContactsEmpty,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: tg.textSecondary),
                ),
              ),
            );
          }
          return ListView(
            children: [
              if (account != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text(
                    account.bareJid,
                    style: TextStyle(color: tg.textSecondary, fontSize: 13),
                  ),
                ),
              for (final jid in list)
                BanListTile(
                  jid: jid,
                  removeTooltip: l10n.unblockContact(jid),
                  onRemove: () => unawaited(_remove(jid)),
                ),
            ],
          );
        },
      ),
    );
  }
}
