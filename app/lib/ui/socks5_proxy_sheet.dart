// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// SOCKS5 controls usable before login (settings alone would be unreachable
// when a bad proxy blocks connect).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../net/app_network.dart';
import '../state/providers.dart';

/// Bottom sheet: enable SOCKS5 + local port (host stays loopback).
Future<void> showSocks5ProxySheet(BuildContext context, WidgetRef ref) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
      child: _Socks5ProxySheet(ref: ref),
    ),
  );
}

class _Socks5ProxySheet extends StatefulWidget {
  const _Socks5ProxySheet({required this.ref});

  final WidgetRef ref;

  @override
  State<_Socks5ProxySheet> createState() => _Socks5ProxySheetState();
}

class _Socks5ProxySheetState extends State<_Socks5ProxySheet> {
  bool _enabled = false;
  bool _ready = false;
  final _port = TextEditingController(text: '7890');

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = widget.ref.read(databaseProvider);
    final enabled = await db.socks5ProxyEnabled();
    final port = await db.socks5ProxyPort();
    if (!mounted) return;
    setState(() {
      _enabled = enabled;
      _port.text = '$port';
      _ready = true;
    });
  }

  @override
  void dispose() {
    _port.dispose();
    super.dispose();
  }

  Future<void> _apply({bool? enabled}) async {
    final l10n = context.l10n;
    final nextEnabled = enabled ?? _enabled;
    final parsed = int.tryParse(_port.text.trim());
    if (parsed == null || parsed < 1 || parsed > 65535) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.socks5ProxyInvalidPort)));
      return;
    }
    final db = widget.ref.read(databaseProvider);
    final host = await db.socks5ProxyHost();
    await db.setSocks5ProxyEnabled(nextEnabled);
    await db.setSocks5ProxyPort(parsed);
    appNetwork.config = Socks5ProxyConfig(
      enabled: nextEnabled,
      host: host,
      port: parsed,
    );
    if (!mounted) return;
    setState(() {
      _enabled = nextEnabled;
      _port.text = '$parsed';
    });
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(l10n.socks5ProxyApplied)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    if (!_ready) {
      return const SizedBox(
        height: 160,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SwitchListTile(
              secondary: const Icon(Icons.vpn_key_outlined),
              title: Text(l10n.socks5Proxy),
              subtitle: Text(l10n.socks5ProxySummary),
              value: _enabled,
              onChanged: (v) => _apply(enabled: v),
            ),
            if (_enabled)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: TextField(
                  controller: _port,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: l10n.socks5ProxyPort,
                    helperText: l10n.socks5ProxyPortHint,
                    prefixText: '127.0.0.1:',
                  ),
                  onSubmitted: (_) => _apply(),
                  onEditingComplete: () => _apply(),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
