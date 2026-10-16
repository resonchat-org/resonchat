// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Shared blocks for 1:1 [ProfilePage] and MUC [RoomProfilePage]: encryption
// entry, notification mode, and local history actions.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:moxxmpp/moxxmpp.dart' show JID;

import '../../account/resolve.dart';
import '../../crypto/omemo/track.dart';
import '../../crypto/omemo/track_resolver.dart';
import '../../l10n/l10n.dart';
import '../../platform/media_store.dart';
import '../../state/providers.dart';
import '../../store/chat_notify_mode.dart';
import '../../xmpp/capabilities.dart';
import '../chats/notify_mode_sheet.dart';
import '../theme.dart';

/// Section title used on chat detail / profile lists.
class ChatProfileSectionTitle extends StatelessWidget {
  const ChatProfileSectionTitle(this.title, {super.key});

  final String title;

  @override
  Widget build(BuildContext context) {
    final tg = context.tg;
    return Padding(
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
}

/// Track summary + link to the encryption / fingerprint page.
class ChatEncryptionSection extends ConsumerWidget {
  const ChatEncryptionSection({
    super.key,
    required this.chatJid,
    this.showTrackPickerHint = true,
  });

  final String chatJid;

  /// When false (e.g. public MUC), still show the details link but omit the
  /// track tile that only applies to encryptable chats.
  final bool showTrackPickerHint;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tg = context.tg;
    final l10n = context.l10n;
    final track = ref.watch(chatTrackProvider(chatJid)).value ?? Track.standard;
    final caps = ref.watch(chatCapabilitiesProvider(chatJid)).value;
    final chat = ref.watch(chatProvider(chatJid)).value;
    final isGroup = chat?.isGroup ?? false;
    final mucEncryptable = chat?.mucPrivateNonAnonymous ?? false;
    final effectiveTrack = isGroup && !mucEncryptable ? Track.none : track;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ChatProfileSectionTitle(l10n.encryption),
        if (showTrackPickerHint && (!isGroup || mucEncryptable))
          ListTile(
            leading: Icon(
              effectiveTrack.icon,
              color: effectiveTrack == Track.none
                  ? tg.textSecondary
                  : tg.accent,
            ),
            title: Text(
              l10n.thisConversationTrack(
                effectiveTrack.localizedDescription(l10n),
              ),
            ),
            subtitle: Text(protectionSentence(effectiveTrack, caps, context)),
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
      ],
    );
  }
}

/// Notification mode row (same sheet as the chats list).
class ChatNotifySection extends ConsumerWidget {
  const ChatNotifySection({super.key, required this.chatJid});

  final String chatJid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final chat = ref.watch(chatProvider(chatJid)).value;
    if (chat == null) {
      return ChatProfileSectionTitle(l10n.notificationSettings);
    }
    final mode = chatNotifyModeOf(
      muted: chat.muted,
      alwaysNotify: chat.alwaysNotify,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ChatProfileSectionTitle(l10n.notificationSettings),
        ListTile(
          leading: Icon(notifyModeIcon(mode)),
          title: Text(l10n.notificationSettings),
          subtitle: Text(notifyModeLabel(l10n, mode)),
          onTap: () => openChatNotifySettings(context, chatJid),
        ),
      ],
    );
  }
}

/// Load MAM + clear local transcript (server archive untouched).
class ChatHistoryActions extends StatelessWidget {
  const ChatHistoryActions({super.key, required this.chatJid});

  final String chatJid;

  @override
  Widget build(BuildContext context) {
    final tg = context.tg;
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          leading: const Icon(Icons.history),
          title: Text(l10n.loadArchivedMessages),
          subtitle: Text(l10n.loadArchivedMessagesSummary),
          onTap: () => loadChatHistory(context, chatJid),
        ),
        ListTile(
          leading: Icon(Icons.delete_outline, color: tg.danger),
          title: Text(
            l10n.clearHistoryOnDevice,
            style: TextStyle(color: tg.danger),
          ),
          subtitle: Text(l10n.clearHistoryOnDeviceSummary),
          onTap: () => confirmClearChatHistory(context, chatJid),
        ),
      ],
    );
  }
}

/// What the chosen track currently means for sending.
String protectionSentence(
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

Future<void> loadChatHistory(BuildContext context, String chatJid) async {
  final resolved = resolveChatKey(chatJid);
  final messenger = ScaffoldMessenger.of(context);
  final l10n = context.l10n;
  final count = await resolved.session.xmpp.fetchHistory(
    JID.fromString(resolved.jid),
  );
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

Future<void> confirmClearChatHistory(
  BuildContext context,
  String chatJid,
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
  if (confirmed != true || !context.mounted) return;
  final resolved = resolveChatKey(chatJid);
  final db = resolved.session.db;
  final bare = resolved.jid;
  final paths = await db.localPathsForChat(bare);
  await db.clearChatMessages(bare);
  await mediaStore.deletePaths(paths);
}
