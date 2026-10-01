// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import '../store/roster_state.dart';
import '../xmpp/connection.dart';

/// M1 login: JID + password (+ optional host override for test servers).
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
  String? _error;

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
        setState(() => _error = 'Authentication failed');
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
      if (mounted) Navigator.of(context).pushReplacementNamed('/chats');
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('resonchat')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            TextField(
              controller: _jid,
              decoration: const InputDecoration(labelText: 'JID'),
            ),
            TextField(
              controller: _password,
              decoration: const InputDecoration(labelText: 'Password'),
              obscureText: true,
            ),
            TextField(
              controller: _host,
              decoration: const InputDecoration(
                labelText: 'Host (optional)',
              ),
            ),
            const SizedBox(height: 16),
            if (_error != null)
              Text(_error!, style: const TextStyle(color: Colors.red)),
            ElevatedButton(
              onPressed: _busy ? null : _connect,
              child: Text(_busy ? 'Connecting…' : 'Connect'),
            ),
          ],
        ),
      ),
    );
  }
}
