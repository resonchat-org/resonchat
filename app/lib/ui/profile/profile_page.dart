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

import '../../account/resolve.dart';
import '../../crypto/omemo/track.dart';
import '../../crypto/omemo/track_resolver.dart';
import '../../l10n/l10n.dart';
import '../../platform/media_store.dart';
import '../../store/database.dart';
import '../../xmpp/capabilities.dart';
import '../../state/providers.dart';
import '../../xmpp/connection.dart';
import '../chats/notify_mode_sheet.dart';
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
    final caps = ref.watch(chatCapabilitiesProvider(chatJid)).value;
    final track = ref.watch(chatTrackProvider(chatJid)).value ?? Track.standard;
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

          _section(tg, l10n.relationship),
          ListTile(
            leading: Icon(
              contact?.isMutual ?? false ? Icons.how_to_reg : Icons.person_add,
              color: contact?.isMutual ?? false
                  ? tg.unreadBadge
                  : tg.unreadBadge,
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

          _section(tg, l10n.encryption),
          ListTile(
            leading: Icon(
              track.icon,
              color: track == Track.none ? tg.textSecondary : tg.accent,
            ),
            title: Text(
              l10n.thisConversationTrack(track.localizedDescription(l10n)),
            ),
            subtitle: Text(protectionSentence(track, caps, context)),
          ),
          ListTile(
            leading: const Icon(Icons.devices_other),
            title: Text(
              l10n.devicesThatCanRead(caps?.recipientDevices.length ?? 0),
            ),
            subtitle: Text(
              caps == null || caps.recipientDevices.isEmpty
                  ? l10n.noDeviceListYet
                  : l10n.deviceListDecidesSending,
              style: TextStyle(fontSize: 12, color: tg.textSecondary),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.fingerprint),
            title: Text(l10n.encryptionDetails),
            subtitle: Text(l10n.fingerprintAndVerification),
            trailing: const Icon(Icons.chevron_right),
            onTap: () =>
                Navigator.of(context)
                    .pushNamed('/encryption', arguments: chatJid),
          ),

          _section(tg, l10n.notificationSettings),
          if (chat != null)
            ListTile(
              leading: Icon(
                notifyModeIcon(
                  chatNotifyModeOf(
                    muted: chat.muted,
                    alwaysNotify: chat.alwaysNotify,
                  ),
                ),
              ),
              title: Text(l10n.notificationSettings),
              subtitle: Text(
                notifyModeLabel(
                  l10n,
                  chatNotifyModeOf(
                    muted: chat.muted,
                    alwaysNotify: chat.alwaysNotify,
                  ),
                ),
              ),
              onTap: () => openChatNotifySettings(context, chatJid),
            ),

          _section(tg, l10n.actions),
          ListTile(
            leading: const Icon(Icons.history),
            title: Text(l10n.loadArchivedMessages),
            subtitle: Text(l10n.loadArchivedMessagesSummary),
            onTap: () => _loadHistory(context, xmpp, peer),
          ),
          ListTile(
            leading: Icon(Icons.delete_outline, color: tg.danger),
            title: Text(
              l10n.clearHistoryOnDevice,
              style: TextStyle(color: tg.danger),
            ),
            subtitle: Text(l10n.clearHistoryOnDeviceSummary),
            onTap: () => _confirmClear(context, resolved.session.db, peer),
          ),
        ],
      ),
    );
  }

  Future<void> _loadHistory(
    BuildContext context,
    XmppService xmpp,
    String peer,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = context.l10n;
    final count = await xmpp.fetchHistory(JID.fromString(peer));
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          count == null
              ? l10n.couldNotLoadHistory
              : l10n.loadedArchivedMessages(count),
        ),
      ),
    );
  }

  Future<void> _confirmClear(
    BuildContext context,
    AppDatabase db,
    String peer,
  ) async {
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.clearHistoryTitle),
        content: Text(l10n.clearHistoryBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.clear),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final paths = await db.localPathsForChat(peer);
    await db.clearChatMessages(peer);
    await mediaStore.deletePaths(paths);
  }

  /// What this conversation will actually do, as distinct from what the user
  /// picked.
  ///
  /// The chosen track is reported first and on its own, because it is the
  /// decision. Whether it is currently usable is a second, separate fact — and
  /// conflating the two is what makes a "protected" badge show on a
  /// conversation whose messages are not being protected.
  static String protectionSentence(
    Track track,
    ChatCapabilities? caps,
    BuildContext context,
  ) {
    final l10n = context.l10n;
    final resolution = resolveTrack(requested: track, capabilities: caps);
    if (!resolution.canSend) {
      return l10n.choseTrackBlocked(
        track.localizedDescription(l10n),
        resolution.blocked!.localizedConsequence(l10n),
      );
    }
    return switch (track) {
      Track.pq => l10n.protectedPq,
      Track.standard => l10n.protectedStandard,
      Track.none => l10n.protectedNone,
    };
  }

  static Widget _section(TgColors tg, String title) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
    child: Text(
      title,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: tg.textSecondary,
      ),
    ),
  );
}
