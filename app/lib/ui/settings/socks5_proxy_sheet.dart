// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Shared SOCKS5 editor (login + settings). Prefs live in [appPrefs].

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../net/app_network.dart';
import '../../store/prefs_database.dart';

/// Bottom sheet: enable SOCKS5 + host + port.
Future<void> showSocks5ProxySheet(BuildContext context, WidgetRef ref) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
      child: const _Socks5ProxySheet(),
    ),
  );
}

class _Socks5ProxySheet extends StatefulWidget {
  const _Socks5ProxySheet();

  @override
  State<_Socks5ProxySheet> createState() => _Socks5ProxySheetState();
}

class _Socks5ProxySheetState extends State<_Socks5ProxySheet> {
  bool _enabled = false;
  bool _ready = false;
  final _host = TextEditingController(text: '127.0.0.1');
  final _port = TextEditingController(text: '7890');

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = appPrefs;
    final enabled = await prefs.socks5ProxyEnabled();
    final host = await prefs.socks5ProxyHost();
    final port = await prefs.socks5ProxyPort();
    if (!mounted) return;
    setState(() {
      _enabled = enabled;
      _host.text = host;
      _port.text = '$port';
      _ready = true;
    });
  }

  Future<void> _apply({bool? enabled}) async {
    final l10n = context.l10n;
    final nextEnabled = enabled ?? _enabled;
    final host = _host.text.trim();
    if (host.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.socks5ProxyInvalidHost)));
      return;
    }
    final parsed = int.tryParse(_port.text.trim());
    if (parsed == null || parsed < 1 || parsed > 65535) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.socks5ProxyInvalidPort)));
      return;
    }

    await appPrefs.setSocks5ProxyEnabled(nextEnabled);
    await appPrefs.setSocks5ProxyHost(host);
    await appPrefs.setSocks5ProxyPort(parsed);
    appNetwork.config = Socks5ProxyConfig(
      enabled: nextEnabled,
      host: host,
      port: parsed,
    );

    if (!mounted) return;
    setState(() {
      _enabled = nextEnabled;
      _host.text = host;
      _port.text = '$parsed';
    });
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(l10n.socks5ProxyApplied)));
  }

  /// Persist current fields when the sheet is dismissed without an explicit
  /// submit (same prefs path as [_apply]).
  void _persistIfValid() {
    if (!_ready) return;
    final host = _host.text.trim();
    final parsed = int.tryParse(_port.text.trim());
    if (host.isEmpty || parsed == null || parsed < 1 || parsed > 65535) {
      return;
    }
    final cfg = Socks5ProxyConfig(enabled: _enabled, host: host, port: parsed);
    if (cfg == appNetwork.config) return;
    appNetwork.config = cfg;
    unawaited(() async {
      await appPrefs.setSocks5ProxyEnabled(cfg.enabled);
      await appPrefs.setSocks5ProxyHost(cfg.host);
      await appPrefs.setSocks5ProxyPort(cfg.port);
    }());
  }

  @override
  void dispose() {
    _persistIfValid();
    _host.dispose();
    _port.dispose();
    super.dispose();
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
            if (_enabled) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: TextField(
                  controller: _host,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: InputDecoration(labelText: l10n.socks5ProxyHost),
                  onSubmitted: (_) => _apply(),
                  onEditingComplete: () => _apply(),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: TextField(
                  controller: _port,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: l10n.socks5ProxyPort,
                    helperText: l10n.socks5ProxyPortHint,
                  ),
                  onSubmitted: (_) => _apply(),
                  onEditingComplete: () => _apply(),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
