// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// MUC ban list (XEP-0045 affiliation=outcast).

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:resonchat/account/resolve.dart';
import 'package:resonchat/l10n/l10n.dart';
import 'package:resonchat/ui/ban_list.dart';
import 'package:resonchat/ui/theme.dart';
import 'package:resonchat/xmpp/muc/muc.dart';

class RoomOutcastsPage extends ConsumerStatefulWidget {
  const RoomOutcastsPage({super.key, required this.chatKey});

  final String chatKey;

  @override
  ConsumerState<RoomOutcastsPage> createState() => _RoomOutcastsPageState();
}

class _RoomOutcastsPageState extends ConsumerState<RoomOutcastsPage> {
  bool _loading = true;
  bool _busy = false;
  String? _error;
  List<Occupant> _outcasts = const [];

  String get _roomJid => resolveChatKey(widget.chatKey).jid;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_reload());
    });
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await resolveChatKey(widget.chatKey).session.xmpp
          .fetchRoomOutcasts(_roomJid);
      list.sort((a, b) => (a.realJid ?? a.nick).compareTo(b.realJid ?? b.nick));
      if (!mounted) return;
      setState(() {
        _outcasts = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _unban(String jid) async {
    if (_busy) return;
    final l10n = context.l10n;
    setState(() => _busy = true);
    final ok = await resolveChatKey(widget.chatKey).session.xmpp
        .unbanJid(_roomJid, jid);
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.unbanFailed)));
      return;
    }
    setState(() {
      _outcasts = _outcasts.where((x) => x.realJid != jid).toList();
    });
  }

  Future<void> _add() async {
    final l10n = context.l10n;
    final result = await showAddBanJidDialog(
      context,
      title: l10n.addToBanList,
      confirmLabel: l10n.banFromRoom,
      askReason: true,
    );
    if (result == null || !mounted) return;
    setState(() => _busy = true);
    final ok = await resolveChatKey(widget.chatKey).session.xmpp.banJid(
      _roomJid,
      result.jid,
      reason: result.reason.isEmpty ? null : result.reason,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.banFailed)));
      return;
    }
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final tg = context.appColors;
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.roomOutcasts),
        actions: [
          IconButton(
            tooltip: l10n.refresh,
            onPressed: _loading || _busy ? null : () => unawaited(_reload()),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _busy ? null : () => unawaited(_add()),
        tooltip: l10n.addToBanList,
        child: const Icon(Icons.person_add_disabled_outlined),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_error!, style: TextStyle(color: tg.danger)),
              ),
            )
          : _outcasts.isEmpty
          ? Center(
              child: Text(
                l10n.roomOutcastsEmpty,
                style: TextStyle(color: tg.textSecondary),
              ),
            )
          : ListView(
              children: [
                for (final o in _outcasts)
                  BanListTile(
                    jid: o.realJid ?? o.nick,
                    detail: o.reason,
                    removeTooltip: l10n.unbanFromRoom,
                    enabled: !_busy,
                    onRemove: () => unawaited(_unban(o.realJid ?? '')),
                  ),
              ],
            ),
    );
  }
}
