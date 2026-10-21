// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// One row of the chat list. The shared layout lives in [DialogCell]; this
// file adds the conversation's encryption track, unread count, and flags.
//
// Inlining all of that into the list page made the list unreadable.
//
// Pin / mute are local. Archive follows Conversations: local flag plus, for
// groups, leave + bookmark autoJoin=false (see conversation_archive.dart).
//
// Trailing swipe follows Telegram DialogsActivity.SwipeController: reveal an
// action pane (flutter_slidable), then tap — never fire on release alone.

import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_slidable/flutter_slidable.dart';

import 'package:resonchat/account/account_color.dart';
import 'package:resonchat/account/account_hub.dart';
import 'package:resonchat/account/resolve.dart';
import 'package:resonchat/crypto/dual/track.dart';
import 'package:resonchat/l10n/l10n.dart';
import 'package:resonchat/persistence/database.dart';
import 'package:resonchat/state/providers.dart';
import 'package:resonchat/ui/account_list_chrome.dart';
import 'package:resonchat/ui/chats/notify_mode_sheet.dart';
import 'package:resonchat/ui/contact_avatar.dart';
import 'package:resonchat/ui/dialog_cell.dart';
import 'package:resonchat/ui/theme.dart';
import 'package:resonchat/xmpp/chat_notify_mode.dart';
import 'package:resonchat/xmpp/conversation_archive.dart';
import 'package:resonchat/xmpp/roster/local_nickname.dart';

class ChatRow extends ConsumerWidget {
  const ChatRow({
    super.key,
    required this.entry,
    required this.onOpen,
    this.showAccountChrome = true,
    this.selected = false,
  });

  final AccountChat entry;
  final VoidCallback onOpen;

  /// Account halo and via label when the list mixes more than one account.
  final bool showAccountChrome;

  /// Column-mode highlight for the open conversation.
  final bool selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tg = context.tg;
    final chat = entry.chat;
    final chatKey = entry.ref.key;
    final accent = entry.accent;
    final multi = ref.watch(accountHubProvider).accounts.length > 1;
    final title = displayName(
      localNickname: null,
      rosterTitle: chat.title,
      roomTitle: chat.isGroup ? chat.title : '',
      jid: chat.jid,
      isRoom: chat.isGroup,
    );
    final track = chat.isGroup && !chat.mucPrivateNonAnonymous
        ? Track.none
        : ref.watch(chatTrackProvider(chatKey)).value ?? Track.standard;
    final preview = ref.watch(lastMessageProvider(chatKey));
    final locked = track != Track.none;
    final notifyMode = chatNotifyModeOf(
      muted: chat.muted,
      alwaysNotify: chat.alwaysNotify,
    );
    final silenced = notifyMode.isSilenced;
    final l10n = context.l10n;
    // Fully muted only for this shortcut (never ↔ all). Highlights stays in
    // the room/contact profile.
    final fullyMuted = notifyMode == ChatNotifyMode.never;

    // Open restores from archive (Conversations findOrCreate), so archived
    // rows are not slidable. Main list: reveal pin / mute / archive.
    final row = DialogCell(
      onTap: onOpen,
      selected: selected,
      leading: _AccountAvatar(
        chat: chat,
        chatKey: chatKey,
        title: title,
        accent: accent,
        ring: multi && showAccountChrome,
      ),
      title: title,
      titleWeight: chat.unreadCount > 0 && !silenced
          ? FontWeight.w700
          : FontWeight.w500,
      titleLeading: [
        if (chat.pinned) _Flag(icon: Icons.push_pin, color: tg.textSecondary),
        if (silenced)
          _Flag(icon: notifyModeIcon(notifyMode), color: tg.textSecondary),
        if (locked) _Flag(icon: Icons.lock, color: tg.accent),
      ],
      // Before the time, as Telegram draws it: the badge is what the user
      // is acting on and the time is context. Mention `@` sits beside the
      // count (DialogCell drawMention + drawCount).
      titleTrailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (chat.unreadMentions > 0) ...[
            MentionBadge(muted: silenced),
            const SizedBox(width: 4),
          ],
          if (chat.unreadCount > 0) ...[
            UnreadBadge(count: chat.unreadCount, muted: silenced),
            const SizedBox(width: 6),
          ],
          Text(
            _timeOf(chat.lastActivity),
            style: TextStyle(
              fontSize: TgDimens.timeFontSize,
              color: chat.unreadCount > 0 && !silenced
                  ? tg.accent
                  : tg.textSecondary,
            ),
          ),
        ],
      ),
      subtitle: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (multi && showAccountChrome)
            Text(
              accountViaLabel(entry.account.bareJid),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: TgDimens.timeFontSize,
                color: accent,
                fontWeight: FontWeight.w600,
              ),
            ),
          Row(
            children: [
              Expanded(
                child: Text(
                  preview.value ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: TgDimens.chatSubtitleFontSize,
                    color: tg.textSecondary,
                  ),
                ),
              ),
              if (locked)
                Text(
                  track.label,
                  style: TextStyle(
                    fontSize: TgDimens.timeFontSize,
                    color: tg.accent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
        ],
      ),
    );

    if (chat.archived) return row;

    return Slidable(
      key: ValueKey('chat-row-$chatKey'),
      endActionPane: ActionPane(
        motion: const DrawerMotion(),
        extentRatio: 0.58,
        children: [
          SlidableAction(
            onPressed: (ctx) => _togglePinned(ctx, chatKey, chat),
            backgroundColor: tg.accent,
            foregroundColor: Colors.white,
            icon: chat.pinned ? Icons.push_pin_outlined : Icons.push_pin,
            label: chat.pinned ? l10n.unpin : l10n.pin,
          ),
          SlidableAction(
            onPressed: (ctx) => _toggleMute(ctx, chatKey, chat, fullyMuted),
            backgroundColor: tg.textSecondary,
            foregroundColor: Colors.white,
            icon: fullyMuted
                ? Icons.notifications_none
                : Icons.notifications_off,
            label: fullyMuted ? l10n.unmute : l10n.mute,
          ),
          SlidableAction(
            onPressed: (ctx) => _archive(ctx, chatKey, chat),
            backgroundColor: tg.danger,
            foregroundColor: Colors.white,
            icon: Icons.archive_outlined,
            label: l10n.archive,
          ),
        ],
      ),
      child: row,
    );
  }

  static Future<void> _togglePinned(
    BuildContext context,
    String chatKey,
    Chat chat,
  ) async {
    await dbForChatKey(chatKey).setChatFlag(chat.jid, pinned: !chat.pinned);
    if (context.mounted) await Slidable.of(context)?.close();
  }

  static Future<void> _toggleMute(
    BuildContext context,
    String chatKey,
    Chat chat,
    bool fullyMuted,
  ) async {
    final next = fullyMuted ? ChatNotifyMode.all : ChatNotifyMode.never;
    await dbForChatKey(chatKey).setChatNotifyMode(chat.jid, next);
    if (context.mounted) await Slidable.of(context)?.close();
  }

  /// Conversations overview / menu archive.
  static Future<void> _archive(
    BuildContext context,
    String chatKey,
    Chat chat,
  ) async {
    await archiveConversation(chatKey);
    if (context.mounted) await Slidable.of(context)?.close();
  }

  static String _timeOf(DateTime t) {
    // Empty chats sit at the Unix epoch — no clock to show.
    if (!t.isAfter(chatActivityEpoch)) return '';
    final now = DateTime.now();
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    if (t.year == now.year && t.month == now.month && t.day == now.day) {
      return '$h:$m';
    }
    return '${t.day}/${t.month}';
  }
}

/// Avatar with optional account-colored ring (not the contact name).
class _AccountAvatar extends ConsumerWidget {
  const _AccountAvatar({
    required this.chat,
    required this.chatKey,
    required this.title,
    required this.accent,
    required this.ring,
  });

  final Chat chat;
  final String chatKey;
  final String title;
  final Color accent;
  final bool ring;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Groups use the same widget: XEP-0084 when present, else vCard PHOTO
    // (Conversations room avatars), else coloured initial. Presence dots are
    // 1:1 only (Telegram DialogCell; MUC uses occupant lists instead).
    final presence = chat.isGroup
        ? null
        : ref.watch(contactPresenceProvider(chatKey)).value?.show;
    final child = ContactAvatar(
      jid: chat.jid,
      title: title,
      hero: true,
      showPresence: !chat.isGroup,
      presence: presence,
    );
    return accountAvatarRing(show: ring, accent: accent, child: child);
  }
}

/// One of the small icons before the title.
class _Flag extends StatelessWidget {
  const _Flag({required this.icon, required this.color});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Icon(icon, size: 12, color: color),
    );
  }
}

/// The unread count badge.
///
/// Muted conversations draw it hollow rather than filled. The count is still
/// true — there really are unread messages — but a solid badge is a promise to
/// interrupt, and muting is the user declining that promise. Hiding the number
/// altogether would be worse: the user could not tell "read" from "ignored".
class UnreadBadge extends StatelessWidget {
  const UnreadBadge({super.key, required this.count, required this.muted});

  final int count;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final accent = context.tg.accent;
    return Container(
      constraints: const BoxConstraints(minWidth: 20),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: muted ? Colors.transparent : accent,
        borderRadius: BorderRadius.circular(10),
        border: muted ? Border.all(color: accent) : null,
      ),
      child: Text(
        // Capped: a four-figure badge needs a much wider pill and the exact
        // number is not what the user is looking at.
        count > 99 ? '99+' : '$count',
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: TgDimens.timeFontSize,
          fontWeight: FontWeight.w700,
          color: muted ? accent : Colors.white,
        ),
      ),
    );
  }
}

/// Telegram `DialogCell` mention pill: a filled `@` next to the unread count.
class MentionBadge extends StatelessWidget {
  const MentionBadge({super.key, required this.muted});

  final bool muted;

  @override
  Widget build(BuildContext context) {
    final accent = context.tg.accent;
    return Container(
      width: 20,
      height: 20,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: muted ? Colors.transparent : accent,
        shape: BoxShape.circle,
        border: muted ? Border.all(color: accent) : null,
      ),
      child: Text(
        '@',
        style: TextStyle(
          fontSize: TgDimens.timeFontSize,
          fontWeight: FontWeight.w800,
          color: muted ? accent : Colors.white,
          height: 1,
        ),
      ),
    );
  }
}
