// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Contact profile page.
//
// Reached by tapping the avatar in a conversation's top bar, which is where
// every other messenger puts it. It answers the questions the chat screen
// cannot: who is this account, what does the server think of the
// subscription, which devices can read this chat, and has anyone actually
// verified the fingerprints.
//
// Everything here is read from real state. A page that shows plausible
// values is worse than one that shows nothing.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:moxxmpp/moxxmpp.dart' show JID;

import '../state/providers.dart';
import '../xmpp/connection.dart';
import 'theme.dart';

class ProfilePage extends ConsumerWidget {
  const ProfilePage({super.key, required this.chatJid});

  final String chatJid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tg = context.tg;
    final chat = ref.watch(chatProvider(chatJid)).value;
    final contact = ref.watch(contactStateProvider(chatJid)).value;
    final caps = ref.watch(chatCapabilitiesProvider(chatJid)).value;
    final mode = ref.watch(chatEncModeProvider(chatJid));
    final xmpp = ref.watch(xmppServiceProvider);
    final connected = xmpp.state == XmppConnectionState.connected;

    final title = (chat?.title.isNotEmpty ?? false) ? chat!.title : chatJid;

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Column(
              children: [
                CircleAvatar(
                  radius: 44,
                  backgroundColor: tg.accent.withValues(alpha: 0.18),
                  child: Text(
                    title.isEmpty ? '?' : title[0].toUpperCase(),
                    style: TextStyle(
                      fontSize: 34,
                      color: tg.accent,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  title,
                  style: const TextStyle(fontSize: 20),
                ),
                const SizedBox(height: 4),
                Text(
                  chatJid,
                  style: TextStyle(fontSize: 14, color: tg.textSecondary),
                ),
              ],
            ),
          ),

          _section(tg, 'Relationship'),
          ListTile(
            leading: Icon(
              contact?.isMutual ?? false ? Icons.how_to_reg : Icons.person_add,
              color: contact?.isMutual ?? false ? tg.unreadBadge : tg.unreadBadge,
            ),
            title: Text(contact?.summary ?? 'unknown'),
            subtitle: Text(
              contact?.isMutual ?? false
                  ? 'Messages are delivered both ways.'
                  : 'Many servers refuse messages until both sides have '
                      'accepted each other.',
              style: TextStyle(fontSize: 12, color: tg.textSecondary),
            ),
            trailing: (contact?.isMutual ?? true) || !connected
                ? null
                : TextButton(
                    onPressed: () => ref
                        .read(xmppServiceProvider)
                        .requestSubscription(JID.fromString(chatJid)),
                    child: const Text('Ask again'),
                  ),
          ),

          _section(tg, 'Encryption'),
          ListTile(
            leading: Icon(
              mode.name == 'none' ? Icons.lock_open : Icons.lock,
              color: mode.name == 'none' ? tg.textSecondary : tg.accent,
            ),
            title: const Text('This conversation'),
            subtitle: Text(protectionSentence(mode.name, caps?.pqDevices.isNotEmpty ?? false)),
          ),
          ListTile(
            leading: const Icon(Icons.devices_other),
            title: Text(
              'Devices that can read it: ${caps?.recipientDevices.length ?? 0}',
            ),
            subtitle: Text(
              caps == null || caps.recipientDevices.isEmpty
                  ? 'No device list has been resolved yet.'
                  : 'A message must be readable by all of them, so this is '
                      'what decides whether it can be sent at all.',
              style: TextStyle(fontSize: 12, color: tg.textSecondary),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.fingerprint),
            title: const Text('Encryption details'),
            subtitle: const Text('Fingerprint and verification'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () =>
                Navigator.of(context).pushNamed('/encryption', arguments: chatJid),
          ),

          _section(tg, 'Actions'),
          ListTile(
            leading: const Icon(Icons.history),
            title: const Text('Load archived messages'),
            subtitle: const Text('Ask the server for this conversation (MAM)'),
            onTap: () => _loadHistory(context, ref),
          ),
          ListTile(
            leading: Icon(Icons.delete_outline, color: tg.danger),
            title: Text('Clear history on this device', style: TextStyle(color: tg.danger)),
            subtitle: const Text('Does not delete anything on the server'),
            onTap: () => _confirmClear(context, ref),
          ),
        ],
      ),
    );
  }

  Future<void> _loadHistory(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final count = await ref
        .read(xmppServiceProvider)
        .fetchHistory(JID.fromString(chatJid));
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          count == null
              ? 'Could not load history (server may not support MAM)'
              : 'Loaded $count archived message(s)',
        ),
      ),
    );
  }

  Future<void> _confirmClear(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear history?'),
        content: const Text(
          'Messages in this conversation will be removed from this device. '
          'Nothing is deleted on the server, and the other side keeps its '
          'copy.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(databaseProvider).clearChatMessages(chatJid);
  }

  static String protectionSentence(String mode, bool hasPq) => switch (mode) {
        'pqOmemo' => 'End-to-end encrypted with post-quantum keys.',
        'standardOmemo' =>
          'End-to-end encrypted (standard OMEMO, works with other apps).',
        _ => hasPq
            ? 'Not encrypted right now, although a post-quantum bundle exists.'
            : 'Not encrypted — no compatible device found.',
      };

  static Widget _section(TgColors tg, String title) => Padding(
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
}