// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Unattended login for smoke tests (see tool/smoke_test.sh).
//
// Enabled only in debug builds via --dart-define=RESONCHAT_SMOKE=<jid>:<pass>
// so automated runs never need to drive the on-screen keyboard, and no
// credential can be baked into a release build. Repeated logins reuse the
// persisted OMEMO device instead of registering a new one.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import '../store/roster_state.dart';
import '../xmpp/connection.dart';
import 'theme.dart';

/// Parsed `--dart-define` credentials, or null when unset.
({String jid, String password})? smokeCredentials() {
  if (!kDebugMode) return null;
  const raw = String.fromEnvironment('RESONCHAT_SMOKE');
  if (raw.isEmpty) return null;
  final split = raw.indexOf(':');
  if (split <= 0) return null;
  return (
    jid: raw.substring(0, split),
    password: raw.substring(split + 1),
  );
}

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

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
    final smoke = smokeCredentials();
    if (smoke != null) {
      _jid.text = smoke.jid;
      _password.text = smoke.password;
      // Run once the first frame is up so Riverpod overrides are ready.
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
      final xmpp = ref.read(xmppServiceProvider);
      final ok = await xmpp.connect(
        jid: _jid.text.trim(),
        password: _password.text,
        host: _host.text.trim().isEmpty ? null : _host.text.trim(),
        rosterState: DriftRosterStateManager(ref.read(databaseProvider)),
      );
      if (!ok) {
        setState(
          () => _error = xmpp.lastError ?? 'Authentication failed',
        );
        return;
      }
      ref.read(connectionStateProvider.notifier).state =
          XmppConnectionState.connected;
      final items = await xmpp.requestRoster();
      for (final item in items) {
        await ref.read(databaseProvider).upsertChat(
              item.jid,
              title: item.name ?? item.jid,
            );
      }
      await xmpp.ensureOmemoDevice();
      // Keep the one-time-prekey pool full so new inbound sessions keep
      // forward secrecy.
      await xmpp.replenishPrekeys();
      if (mounted) Navigator.of(context).pushReplacementNamed('/chats');
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tg = context.tg;
    return Scaffold(
      appBar: AppBar(title: const Text('resonchat')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _jid,
                decoration: const InputDecoration(labelText: 'JID'),
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _password,
                decoration: const InputDecoration(labelText: 'Password'),
                obscureText: true,
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _host,
                decoration: const InputDecoration(
                  labelText: 'Host (optional)',
                ),
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _connect(),
              ),
              const SizedBox(height: 24),
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
                child: Text(_busy ? 'Connecting…' : 'Connect'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}