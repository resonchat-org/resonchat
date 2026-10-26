// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Account creation UI. Protocol follows Conversations (XEP-0077); server
// choice follows Copinc — every provider is equal, no conversations.im hero.

import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import 'package:moxxmpp/moxxmpp.dart' show ExtendedRegistration;

import 'package:resonchat/l10n/connect_failure_label.dart';
import 'package:resonchat/l10n/l10n.dart';
import 'package:resonchat/net/app_network.dart';
import 'package:resonchat/ui/login/login_viewmodel.dart';
import 'package:resonchat/ui/settings/socks5_proxy_sheet.dart';
import 'package:resonchat/ui/theme.dart';
import 'package:resonchat/xmpp/registration.dart';

final _log = Logger('RegisterPage');

class RegisterPage extends ConsumerStatefulWidget {
  const RegisterPage({super.key, this.addAccountMode = false});

  /// Opened from Manage Accounts rather than first-run.
  final bool addAccountMode;

  @override
  ConsumerState<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends ConsumerState<RegisterPage> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _password2 = TextEditingController();
  final _ownDomain = TextEditingController();
  final _host = TextEditingController();

  late List<String> _providers;
  late String _selectedDomain;
  bool _useOwn = false;
  bool _busy = false;
  bool _fetchingProviders = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _providers = List<String>.from(kPublicXmppProviders)..shuffle(Random());
    _selectedDomain = _providers.first;
  }

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    _password2.dispose();
    _ownDomain.dispose();
    _host.dispose();
    super.dispose();
  }

  String? get _domain {
    if (_useOwn) {
      final d = _ownDomain.text.trim().toLowerCase();
      return d.isEmpty ? null : d;
    }
    return _selectedDomain;
  }

  String? get _fullJid {
    final user = _username.text.trim();
    final domain = _domain;
    if (user.isEmpty || domain == null) return null;
    return '$user@$domain';
  }

  /// Gajim-style: opt-in download of providers-B.json; replaces the default
  /// queue entirely on success (keeps the previous list on failure).
  Future<void> _fetchProviders() async {
    if (_fetchingProviders || _busy) return;
    final l10n = context.l10n;
    setState(() {
      _fetchingProviders = true;
      _error = null;
    });
    try {
      final fetched = await fetchPublicXmppProviders();
      if (!mounted) return;
      final next = List<String>.from(fetched)..shuffle(Random());
      setState(() {
        _providers = next;
        _selectedDomain = next.first;
        _fetchingProviders = false;
      });
    } catch (e, st) {
      _log.warning('providers list fetch failed', e, st);
      if (!mounted) return;
      setState(() {
        _fetchingProviders = false;
        _error = l10n.fetchProvidersListFailed;
      });
    }
  }

  Future<String?> _askCaptcha(ExtendedRegistration challenge) async {
    if (!mounted) return null;
    final controller = TextEditingController();
    final answer = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        final l10n = ctx.l10n;
        return AlertDialog(
          title: Text(l10n.registrationCaptchaTitle),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Image.memory(
                  Uint8List.fromList(challenge.captchaBytes),
                  fit: BoxFit.contain,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: l10n.registrationCaptchaHint,
                  ),
                  onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(l10n.cancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: Text(l10n.register),
            ),
          ],
        );
      },
    );
    await WidgetsBinding.instance.endOfFrame;
    controller.dispose();
    return answer;
  }

  Future<void> _register() async {
    final l10n = context.l10n;
    final jid = _fullJid;
    final password = _password.text;
    if (jid == null) {
      setState(() => _error = l10n.registrationNeedUsernameAndServer);
      return;
    }
    if (_username.text.trim().length < 3) {
      setState(() => _error = l10n.registrationInvalidUsername);
      return;
    }
    if (password.isEmpty) {
      setState(() => _error = l10n.registrationNeedPassword);
      return;
    }
    if (password != _password2.text) {
      setState(() => _error = l10n.registrationPasswordMismatch);
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    final created = await registerAccount(
      jid: jid,
      password: password,
      host: _host.text.trim().isEmpty ? null : _host.text.trim(),
      onCaptcha: _askCaptcha,
      registrationFailedLabel: l10n.registrationFailed,
      registrationNotSupportedLabel: l10n.registrationNotSupported,
      registrationConflictLabel: l10n.registrationConflict,
      registrationPasswordWeakLabel: l10n.registrationPasswordTooWeak,
      registrationCaptchaLabel: l10n.registrationInvalidCaptcha,
      registrationPleaseWaitLabel: l10n.registrationPleaseWait,
    );

    if (!mounted) return;

    if (created.redirectUrl != null) {
      setState(() {
        _busy = false;
        _error = l10n.registrationWebRequired(created.redirectUrl.toString());
      });
      return;
    }
    if (!created.success) {
      setState(() {
        _busy = false;
        _error = created.error ?? l10n.registrationFailed;
      });
      return;
    }

    // Account exists on the server — log in like a normal connect.
    final login = await ref
        .read(loginViewModelProvider.notifier)
        .connect(jid: jid, password: password, host: _host.text);
    if (!mounted) return;
    setState(() => _busy = false);
    if (!login.success) {
      setState(() => _error = connectFailureLabel(l10n, login.failure));
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
    final preview = _fullJid;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.createAccount)),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.pickAServer,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                l10n.serverSelectText,
                style: TextStyle(color: tg.textSecondary),
              ),
              const SizedBox(height: 16),
              InputDecorator(
                decoration: InputDecoration(
                  labelText: l10n.chooseYourServer,
                  enabled: !_useOwn && !_fetchingProviders,
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    isExpanded: true,
                    value: _providers.contains(_selectedDomain)
                        ? _selectedDomain
                        : null,
                    items: [
                      for (final d in _providers)
                        DropdownMenuItem(value: d, child: Text(d)),
                    ],
                    onChanged: _useOwn || _fetchingProviders
                        ? null
                        : (v) {
                            if (v == null) return;
                            setState(() => _selectedDomain = v);
                          },
                  ),
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _useOwn || _fetchingProviders || _busy
                      ? null
                      : _fetchProviders,
                  icon: _fetchingProviders
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.cloud_download_outlined, size: 18),
                  label: Text(
                    _fetchingProviders
                        ? l10n.fetchingProvidersList
                        : l10n.fetchProvidersList,
                  ),
                ),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.useOwnProvider),
                value: _useOwn,
                onChanged: (v) => setState(() => _useOwn = v ?? false),
              ),
              if (_useOwn)
                TextField(
                  controller: _ownDomain,
                  decoration: InputDecoration(
                    labelText: l10n.serverDomain,
                    hintText: 'example.org',
                  ),
                  textInputAction: TextInputAction.next,
                  onChanged: (_) => setState(() {}),
                ),
              const SizedBox(height: 16),
              TextField(
                controller: _username,
                decoration: InputDecoration(labelText: l10n.username),
                textInputAction: TextInputAction.next,
                autocorrect: false,
                onChanged: (_) => setState(() {}),
              ),
              if (preview != null) ...[
                const SizedBox(height: 8),
                Text(
                  l10n.yourFullJidWillBe(preview),
                  style: TextStyle(color: tg.textSecondary, fontSize: 13),
                ),
              ],
              const SizedBox(height: 12),
              TextField(
                controller: _password,
                decoration: InputDecoration(labelText: l10n.password),
                obscureText: true,
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _password2,
                decoration: InputDecoration(labelText: l10n.confirmPassword),
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
                onSubmitted: (_) => _busy ? null : _register(),
              ),
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
                onPressed: _busy ? null : _register,
                style: ElevatedButton.styleFrom(
                  backgroundColor: tg.accent,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: Text(_busy ? l10n.registering : l10n.createAccount),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
