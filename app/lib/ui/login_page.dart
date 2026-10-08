// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// First-run login, or "add account" from Manage Accounts (Conversations
// EditAccountActivity). The form itself is never a multi-account switcher.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../account/account_hub.dart';
import '../l10n/l10n.dart';
import '../net/app_network.dart';
import '../state/providers.dart';
import '../xmpp/connection.dart';
import 'socks5_proxy_sheet.dart';
import 'theme.dart';

/// Parsed `--dart-define` credentials, or null when unset.
({String jid, String password})? smokeCredentials() {
  if (!kDebugMode) return null;
  const raw = String.fromEnvironment('RESONCHAT_SMOKE');
  if (raw.isEmpty) return null;
  final split = raw.indexOf(':');
  if (split <= 0) return null;
  return (jid: raw.substring(0, split), password: raw.substring(split + 1));
}

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key, this.addAccountMode = false});

  /// When true, opened from Manage Accounts → Add account.
  final bool addAccountMode;

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  final _jid = TextEditingController();
  final _password = TextEditingController();
  final _host = TextEditingController();
  bool _busy = false;
  bool _smokeRan = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.addAccountMode) return;
    final smoke = smokeCredentials();
    if (smoke != null) {
      _jid.text = smoke.jid;
      _password.text = smoke.password;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _smokeRan) return;
        _smokeRan = true;
        _connect();
      });
    }
  }

  @override
  void dispose() {
    _jid.dispose();
    _password.dispose();
    _host.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await appNetwork.waitUntilReady();
      final hub = accountHub;
      final ok = await hub.addAndConnect(
        jid: _jid.text.trim(),
        password: _password.text,
        host: _host.text.trim().isEmpty ? null : _host.text.trim(),
      );
      if (!ok) {
        setState(
          () => _error =
              hub.lastConnectError ?? context.l10n.authenticationFailed,
        );
        return;
      }

      final session = hub.primarySession;
      if (session == null) {
        setState(() => _error = context.l10n.authenticationFailed);
        return;
      }

      // Shared SOCKS lives on the primary DB. Reload only after first login
      // (add-account reuses the already-loaded global proxy).
      if (!widget.addAccountMode) {
        await appNetwork.loadFrom(() async {
          return Socks5ProxyConfig(
            enabled: await session.db.socks5ProxyEnabled(),
            host: await session.db.socks5ProxyHost(),
            port: await session.db.socks5ProxyPort(),
          );
        });
      }

      ref.read(connectionStateProvider.notifier).state =
          XmppConnectionState.connected;
      // Drop any cold-start "no session" provider errors from the login route.
      ref.invalidate(databaseProvider);
      ref.invalidate(xmppServiceProvider);

      // Roster / OMEMO / MAM already ran inside [AccountHub.addAndConnect].
      if (!mounted) return;
      if (widget.addAccountMode) {
        Navigator.of(context).pop();
      } else {
        Navigator.of(context).pushReplacementNamed('/chats');
      }
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tg = context.tg;
    final l10n = context.l10n;
    final proxyOn = appNetwork.config.enabled;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.addAccountMode ? l10n.addAccount : l10n.appName),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _jid,
                decoration: InputDecoration(labelText: l10n.jid),
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _password,
                decoration: InputDecoration(labelText: l10n.password),
                obscureText: true,
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _host,
                decoration: InputDecoration(
                  labelText: l10n.hostOptional,
                  helperText: kIsWeb ? l10n.hostOptionalWebHint : null,
                ),
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _connect(),
              ),
              // One shared SOCKS for every account (primary DB / Settings).
              // Add-account must not offer a second proxy — that would diverge.
              // Browsers cannot do SOCKS CONNECT, so hide the control on web.
              if (!widget.addAccountMode && !kIsWeb) ...[
                const SizedBox(height: 8),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    Icons.vpn_key_outlined,
                    color: proxyOn ? tg.accent : tg.textSecondary,
                  ),
                  title: Text(l10n.socks5Proxy),
                  subtitle: Text(
                    proxyOn
                        ? '${appNetwork.config.host}:${appNetwork.config.port}'
                        : l10n.socks5ProxySummary,
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    await showSocks5ProxySheet(context, ref);
                    if (mounted) setState(() {});
                  },
                ),
              ],
              const SizedBox(height: 16),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    _error!,
                    style: TextStyle(color: tg.danger),
                    textAlign: TextAlign.center,
                  ),
                ),
              ElevatedButton(
                onPressed: _busy ? null : _connect,
                style: ElevatedButton.styleFrom(
                  backgroundColor: tg.accent,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: Text(_busy ? l10n.connecting : l10n.connect),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
