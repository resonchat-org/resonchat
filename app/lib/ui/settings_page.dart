// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../pq/liboqs_mlkem.dart';
import '../omemo/track.dart';
import '../state/providers.dart';
import '../xmpp/connection.dart';
import 'archive_page.dart';
import 'theme.dart';

/// App settings. Deliberately free of branding that would suggest any
/// affiliation with other messengers (docs/05 §6).
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tg = context.tg;
    final xmpp = ref.watch(xmppServiceProvider);
    final native = MlKem768Provider.instance.isNative;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          _header(tg, 'Default encryption'),
          // The global default is a real decision, so it gets the same
          // three-option choice as a conversation does rather than a switch
          // whose "off" state means something different from every other
          // track. Changing it never touches a conversation that has its own
          // choice — only the ones that were following along.
          Consumer(
            builder: (context, ref, _) {
              final current =
                  ref.watch(globalTrackProvider).value ?? Track.standard;
              return Column(
                children: [
                  for (final track in Track.values)
                    RadioListTile<Track>(
                      value: track,
                      // ignore: deprecated_member_use
                      groupValue: current,
                      // ignore: deprecated_member_use
                      onChanged: (value) {
                        if (value != null) setGlobalTrack(ref, value);
                      },
                      title: Text('${track.label}  ${track.description}'),
                      secondary: Icon(
                        track.icon,
                        color: track == Track.none
                            ? tg.danger
                            : tg.accent,
                      ),
                    ),
                ],
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.archive_outlined),
            title: const Text('Archived conversations'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const ArchivePage()),
            ),
          ),

          _header(tg, 'Connection'),
          ListTile(
            leading: const Icon(Icons.cloud_outlined),
            title: const Text('Status'),
            subtitle: Text(_status(xmpp)),
            trailing: Icon(
              xmpp.state == XmppConnectionState.connected
                  ? Icons.check_circle
                  : Icons.error_outline,
              color: xmpp.state == XmppConnectionState.connected
                  ? tg.unreadBadge
                  : tg.danger,
              size: 20,
            ),
          ),
          ListTile(
            leading: const Icon(Icons.sync),
            title: const Text('Message carbons'),
            subtitle: Text(
              xmpp.carbonsEnabled
                  ? 'Enabled — messages sync across your devices'
                  : 'Not enabled by this server',
            ),
          ),
          ListTile(
            leading: const Icon(Icons.archive_outlined),
            title: const Text('Message archive (MAM)'),
            subtitle: Text(
              xmpp.mamAvailable
                  ? 'Server keeps history for this account'
                  : 'Server does not advertise a MAM archive',
            ),
          ),

          _header(tg, 'Encryption'),
          ListTile(
            leading: Icon(
              Icons.bolt,
              color: xmpp.bTrackReady ? tg.accent : tg.textSecondary,
            ),
            title: const Text('Post-quantum track'),
            subtitle: Text(
              xmpp.bTrackReady
                  ? 'Bundle published; chats upgrade automatically'
                  : 'Not published — chats use standard OMEMO',
            ),
          ),
          ListTile(
            leading: const Icon(Icons.memory),
            title: const Text('Post-quantum backend'),
            subtitle: Text(
              native
                  ? 'liboqs (native, hardware accelerated)'
                  : 'pqcrypto (pure Dart)',
            ),
            trailing: Text(
              native ? 'native' : 'dart',
              style: TextStyle(color: tg.textSecondary, fontSize: 12),
            ),
          ),

          _header(tg, 'About'),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 24),
            child: Text(
              'resonchat — a dual-track OMEMO client for XMPP.\n'
              'Licensed GPL-3.0-or-later.\n\n'
              'Independent project. Not affiliated with, endorsed by, or '
              'derived from any other messaging product.\n\n'
              'The post-quantum track is a custom extension and has not been '
              'independently audited. Use at your own risk.',
              style: TextStyle(fontSize: 13, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }

  static Widget _header(TgColors tg, String title) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
        child: Text(
          title,
          style: TextStyle(
            color: tg.accent,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      );

  static String _status(XmppService xmpp) => switch (xmpp.state) {
        XmppConnectionState.connected => 'Connected',
        XmppConnectionState.connecting => 'Connecting…',
        XmppConnectionState.disconnected =>
          xmpp.lastError ?? 'Not connected',
      };
}