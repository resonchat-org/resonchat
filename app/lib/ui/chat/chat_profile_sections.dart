// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Shared blocks for 1:1 [ProfilePage] and MUC [RoomProfilePage]: display
// name, encryption entry, notification mode, appearance, and local history.

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:moxxmpp/moxxmpp.dart' show JID;

import 'package:resonchat/account/resolve.dart';
import 'package:resonchat/crypto/dual/track.dart';
import 'package:resonchat/crypto/dual/track_resolver.dart';
import 'package:resonchat/l10n/l10n.dart';
import 'package:resonchat/persistence/media_store.dart';
import 'package:resonchat/state/providers.dart';
import 'package:resonchat/ui/chat/appearance.dart';
import 'package:resonchat/ui/chats/notify_mode_sheet.dart';
import 'package:resonchat/ui/theme.dart';
import 'package:resonchat/xmpp/chat_notify_mode.dart';
import 'package:resonchat/xmpp/encryption/capabilities.dart';
import 'package:resonchat/xmpp/roster/local_nickname.dart';

/// Display name for a contact or a group chat (Gajim's name row).
///
/// The pencil that edits a room's published name stays on the room header.
/// This row is the name only this user sees, for both contacts and rooms.
class ConversationDisplayNameTile extends ConsumerWidget {
  const ConversationDisplayNameTile({
    super.key,
    required this.chatKey,
    required this.jid,
    required this.isRoom,
    this.roomTitle = '',
  });

  final String chatKey;
  final String jid;
  final bool isRoom;

  /// Disco / roomconfig name, used when the stored title is still empty.
  final String roomTitle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final chat = ref.watch(chatProvider(chatKey)).value;
    final storedTitle = chat?.title ?? '';
    final title = isRoom
        ? (storedTitle.trim().isNotEmpty ? storedTitle : roomTitle)
        : storedTitle;
    final shown = conversationDisplayName(
      storedLocalNickname: chat?.localNickname,
      title: title,
      jid: jid,
      isRoom: isRoom,
    );
    final original = conversationDisplayName(
      storedLocalNickname: null,
      title: title,
      jid: jid,
      isRoom: isRoom,
    );
    final custom = LocalNickname.decode(chat?.localNickname);
    return ListTile(
      leading: const Icon(Icons.drive_file_rename_outline),
      title: Text(l10n.conversationDisplayName),
      subtitle: Text(custom == null ? original : shown),
      onTap: () => unawaited(
        showDialog<void>(
          context: context,
          builder: (context) => _DisplayNameDialog(
            initial: custom?.value ?? '',
            originalName: original,
            onSubmit: (raw) => setConversationDisplayName(ref, chatKey, raw),
          ),
        ),
      ),
    );
  }
}

class _DisplayNameDialog extends StatefulWidget {
  const _DisplayNameDialog({
    required this.initial,
    required this.originalName,
    required this.onSubmit,
  });

  /// The display name already stored, or empty when the original name is in use.
  final String initial;

  /// Roster name or room name, shown so an empty field has an obvious result.
  final String originalName;
  final Future<bool> Function(String raw) onSubmit;

  @override
  State<_DisplayNameDialog> createState() => _DisplayNameDialogState();
}

class _DisplayNameDialogState extends State<_DisplayNameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );
  String? _error;
  var _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _commit(String raw) async {
    final l10n = context.l10n;
    final problem = _problem(l10n, raw);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await widget.onSubmit(raw);
    if (!mounted) return;
    if (!ok) {
      setState(() {
        _busy = false;
        _error = l10n.conversationDisplayNameInvalid;
      });
      return;
    }
    Navigator.of(context).pop();
  }

  String? _problem(AppLocalizations l10n, String raw) {
    if (LocalNickname.tryParse(raw) != null || raw.trim().isEmpty) return null;
    if (raw.trim().runes.length > LocalNickname.maxRunes) {
      return l10n.conversationDisplayNameTooLong(LocalNickname.maxRunes);
    }
    return l10n.conversationDisplayNameInvalid;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.conversationDisplayName),
      content: TextField(
        controller: _controller,
        autofocus: true,
        enabled: !_busy,
        textInputAction: TextInputAction.done,
        onSubmitted: (raw) => unawaited(_commit(raw)),
        decoration: InputDecoration(
          helperText: l10n.conversationDisplayNameHelper,
          helperMaxLines: 3,
          hintText: l10n.conversationDisplayNameEmpty(widget.originalName),
          errorText: _error,
          errorMaxLines: 3,
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => unawaited(_commit('')),
          child: Text(l10n.resetToOriginalName),
        ),
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
        TextButton(
          onPressed: _busy ? null : () => unawaited(_commit(_controller.text)),
          child: Text(l10n.save),
        ),
      ],
    );
  }
}

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

/// Wallpaper / bubble shape (moved here from the chat AppBar palette).
class ChatAppearanceSection extends ConsumerWidget {
  const ChatAppearanceSection({super.key, required this.chatJid});

  final String chatJid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ChatProfileSectionTitle(l10n.appearance),
        ListTile(
          leading: const Icon(Icons.palette_outlined),
          title: Text(l10n.appearance),
          subtitle: Text(l10n.appearanceBackground),
          onTap: () => openChatAppearanceSheet(context, ref, chatJid),
        ),
      ],
    );
  }
}

/// Opens the per-chat appearance sheet (wallpaper + bubble shape).
void openChatAppearanceSheet(
  BuildContext context,
  WidgetRef ref,
  String chatJid,
) {
  final appearance =
      ref.read(chatAppearanceProvider(chatJid)).value ?? const ChatAppearance();
  final bare = resolveChatKey(chatJid).jid;
  unawaited(
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => AppearancePicker(
        chatJid: bare,
        initial: appearance,
        onChanged: (next) => unawaited(setChatAppearance(ref, chatJid, next)),
      ),
    ),
  );
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
  final chat = await resolved.session.db.getChat(resolved.jid);
  final count = await resolved.session.xmpp.fetchHistory(
    JID.fromString(resolved.jid),
    group: chat?.isGroup ?? false,
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
