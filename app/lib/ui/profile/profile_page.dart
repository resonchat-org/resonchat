// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Contact profile page.
//
// Reached by tapping the avatar in a conversation's top bar, which is where
// every other messenger puts it. It answers the questions the chat screen
// cannot: who is this account, what does the server think of the
// subscription, and fingerprint / verification details.
//
// Everything here is read from real state. A page that shows plausible
// values is worse than one that shows nothing.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:moxxmpp/moxxmpp.dart' show JID;

import '../../account/resolve.dart';
import '../../l10n/l10n.dart';
import '../../state/providers.dart';
import '../../xmpp/connection.dart';
import '../chat/chat_profile_sections.dart';
import '../theme.dart';

class ProfilePage extends ConsumerWidget {
  const ProfilePage({super.key, required this.chatJid});

  /// [ChatRef.key] (or legacy bare JID).
  final String chatJid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tg = context.tg;
    final l10n = context.l10n;
    final resolved = resolveChatKey(chatJid);
    final peer = resolved.jid;
    final xmpp = resolved.session.xmpp;
    final chat = ref.watch(chatProvider(chatJid)).value;
    final contact = ref.watch(contactStateProvider(chatJid)).value;
    final connected = xmpp.state == XmppConnectionState.connected;

    final title = (chat?.title.isNotEmpty ?? false) ? chat!.title : peer;

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
                Text(title, style: const TextStyle(fontSize: 20)),
                const SizedBox(height: 4),
                Text(
                  peer,
                  style: TextStyle(fontSize: 14, color: tg.textSecondary),
                ),
              ],
            ),
          ),

          ChatProfileSectionTitle(l10n.relationship),
          ListTile(
            leading: Icon(
              contact?.isMutual ?? false ? Icons.how_to_reg : Icons.person_add,
              color: tg.unreadBadge,
            ),
            title: Text(contact?.summary ?? l10n.subscriptionUnknown),
            subtitle: Text(
              contact?.isMutual ?? false
                  ? l10n.subscriptionMutualSummary
                  : l10n.subscriptionNotMutualSummary,
              style: TextStyle(fontSize: 12, color: tg.textSecondary),
            ),
            trailing: (contact?.isMutual ?? true) || !connected
                ? null
                : TextButton(
                    onPressed: () =>
                        xmpp.requestSubscription(JID.fromString(peer)),
                    child: Text(l10n.askAgain),
                  ),
          ),

          ChatEncryptionSection(chatJid: chatJid),
          ChatNotifySection(chatJid: chatJid),

          ChatProfileSectionTitle(l10n.actions),
          ChatHistoryActions(chatJid: chatJid),
        ],
      ),
    );
  }
}
