// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Encryption info page: per-chat track, our device id, and the identity
// fingerprint users compare with the other side (Briar-style: show, don't
// hide — invariant 4 in docs/01 §7).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../crypto/fingerprint.dart';
import '../omemo/protocol.dart';
import '../state/providers.dart';

class SecurityPage extends ConsumerStatefulWidget {
  const SecurityPage({super.key, required this.chatJid});

  final String chatJid;

  @override
  ConsumerState<SecurityPage> createState() => _SecurityPageState();
}

class _SecurityPageState extends ConsumerState<SecurityPage> {
  String? _fingerprint;
  int? _deviceId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final xmpp = ref.read(xmppServiceProvider);
    final om = xmpp.omemo;
    if (om == null) return;
    final id = await om.getDeviceId();
    final fp = await (await om.getDevice()).getFingerprint();
    if (!mounted) return;
    setState(() {
      _deviceId = id;
      _fingerprint = fp;
    });
  }

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(encModeProvider(widget.chatJid));
    return Scaffold(
      appBar: AppBar(title: Text(widget.chatJid)),
      body: ListView(
        children: [
          ListTile(
            title: const Text('Encryption'),
            subtitle: Text(encModeLabel(mode)),
          ),
          ListTile(
            title: const Text('Our device id'),
            subtitle: Text('${_deviceId ?? '—'}'),
          ),
          ListTile(
            title: const Text('Fingerprint'),
            subtitle: Text(formatFingerprint(_fingerprint ?? '—')),
            onTap: _fingerprint == null
                ? null
                : () async {
                    await Clipboard.setData(
                      ClipboardData(text: _fingerprint!),
                    );
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Copied')),
                      );
                    }
                  },
          ),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Compare this fingerprint in person with the other side. '
              'Both tracks share the same identity key, so one comparison '
              'covers standard OMEMO and the post-quantum track.\n\n'
              'Trust is blind (TOFU) until you verify here.',
              style: TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

/// Settings entry point (M7 fills in power/battery and backup options).
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(connectionStateProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          ListTile(
            title: const Text('Connection'),
            subtitle: Text(state.name),
          ),
          const ListTile(
            title: Text('About'),
            subtitle: Text(
              'resonchat — dual-track OMEMO client (GPL-3.0-or-later).\n'
              'Independent project, not affiliated with Telegram.\n'
              'The post-quantum track is a custom extension and has not '
              'been independently audited.',
            ),
            isThreeLine: true,
          ),
        ],
      ),
    );
  }
}