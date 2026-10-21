// Copyright (C) 2026 ResonChat contributors.
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

import 'package:resonchat/account/resolve.dart';
import 'package:resonchat/l10n/l10n.dart';
import 'package:resonchat/state/providers.dart';
import 'package:resonchat/ui/chat/chat_profile_sections.dart';
import 'package:resonchat/ui/theme.dart';
import 'package:resonchat/xmpp/connection.dart';
import 'package:resonchat/xmpp/roster/last_seen.dart';

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
    final presence = ref.watch(contactPresenceProvider(chatJid)).value;
    final connected = xmpp.state == XmppConnectionState.connected;
    final seen = lastSeenLine(l10n, presence?.idleSince);

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

          ListTile(
            leading: const Icon(Icons.circle_outlined),
            title: Text(presenceLabel(l10n, presence?.show)),
            subtitle: seen == null
                ? null
                : Text(
                    seen,
                    style: TextStyle(fontSize: 12, color: tg.textSecondary),
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
          if (contact?.inRoster == true && chat?.isGroup != true)
            ListTile(
              leading: Icon(Icons.person_remove, color: tg.danger),
              title: Text(
                l10n.deleteContact,
                style: TextStyle(color: tg.danger),
              ),
              subtitle: Text(l10n.deleteContactSummary),
              onTap: connected
                  ? () => confirmDeleteContact(context, chatJid, peer)
                  : () => ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(l10n.notConnectedTryAgain)),
                    ),
            ),
          ChatHistoryActions(chatJid: chatJid),
        ],
      ),
    );
  }
}

/// Conversations contact-details "Delete from roster". The transcript stays.
Future<void> confirmDeleteContact(
  BuildContext context,
  String chatJid,
  String peer,
) async {
  final l10n = context.l10n;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(l10n.deleteContact),
      content: Text(l10n.deleteContactConfirm(peer)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(l10n.cancel),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(l10n.deleteContact),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  final xmpp = resolveChatKey(chatJid).session.xmpp;
  final ok = await xmpp.removeContact(peer);
  if (!context.mounted) return;
  if (!ok) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(l10n.couldNotDeleteContact)));
    return;
  }
  Navigator.of(context).pop();
}
