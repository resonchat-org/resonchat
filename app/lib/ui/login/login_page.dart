// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// First-run login, or "add account" from Manage Accounts (Conversations
// EditAccountActivity). The form itself is never a multi-account switcher.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:resonchat/l10n/connect_failure_label.dart';
import 'package:resonchat/l10n/l10n.dart';
import 'package:resonchat/net/app_network.dart';
import 'package:resonchat/ui/login/login_viewmodel.dart';
import 'package:resonchat/ui/settings/socks5_proxy_sheet.dart';
import 'package:resonchat/ui/theme.dart';
import 'package:resonchat/xmpp/jid_input.dart';

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
    _jid.addListener(() => setState(() {}));
    _password.addListener(() => setState(() {}));
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

  bool get _canConnect =>
      !_busy &&
      completeJidCandidate(_jid.text) != null &&
      _password.text.isNotEmpty;

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
    final result = await ref
        .read(loginViewModelProvider.notifier)
        .connect(jid: _jid.text, password: _password.text, host: _host.text);
    if (!mounted) return;
    setState(() => _busy = false);
    if (!result.success) {
      setState(
        () => _error = connectFailureLabel(context.l10n, result.failure),
      );
      return;
    }
    if (widget.addAccountMode) {
      Navigator.of(context).pop();
    } else {
      Navigator.of(context).pushReplacementNamed('/chats');
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
                decoration: InputDecoration(
                  labelText: l10n.jid,
                  errorText:
                      _jid.text.trim().isNotEmpty &&
                          completeJidCandidate(_jid.text) == null
                      ? l10n.invalidJid
                      : null,
                ),
                textInputAction: TextInputAction.next,
                keyboardType: TextInputType.emailAddress,
                autocorrect: false,
                enableSuggestions: false,
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
              // Shared SOCKS prefs (same sheet as Settings). Add-account must
              // not offer a second proxy. Browsers cannot do SOCKS CONNECT.
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
                onPressed: _canConnect ? _connect : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: tg.accent,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: Text(_busy ? l10n.connecting : l10n.connect),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: _busy
                    ? null
                    : () {
                        Navigator.of(context).pushNamed(
                          '/register',
                          arguments: widget.addAccountMode,
                        );
                      },
                child: Text(l10n.createAccount),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
