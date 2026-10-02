// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// One row of the chat list.
//
// Its own file because the row has grown past "a title, a preview and a
// timestamp": it now carries the conversation's encryption track, its unread
// count, and four user-set flags, and inlining all of that into the list page
// made the list unreadable.
//
// The flags (pinned, muted, archived) are per conversation and local. There is
// no standard way to tell a server "stop notifying me about this contact", and
// pretending otherwise would produce a setting that silently does nothing on
// the user's other device.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../omemo/track.dart';
import '../state/providers.dart';
import '../store/database.dart';
import 'contact_avatar.dart';
import 'theme.dart';

/// The two swipe gestures on a chat row.
enum ChatSwipeAction {
  /// Swipe in from the leading edge.
  toggleMute,

  /// Swipe in from the trailing edge.
  togglePin,
}

class ChatRow extends ConsumerWidget {
  const ChatRow({
    super.key,
    required this.chat,
    required this.onOpen,
  });

  final Chat chat;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tg = context.tg;
    final title = chat.title.isEmpty ? chat.jid : chat.title;
    // The chosen track, not the negotiated one: a row says what the user
    // picked. Whether it can be used right now is a question for the chat page
    // and for the moment of sending.
    final track = ref.watch(chatTrackProvider(chat.jid)).value ?? Track.standard;
    final preview = ref.watch(lastMessageProvider(chat.jid));
    final locked = track != Track.none;

    return Dismissible(
      // Required, and correct anyway: every dismissible in a list needs an
      // identity of its own, and the conversation's JID is exactly that.
      key: ValueKey('chat-row-${chat.jid}'),
      // Both directions, so the row is swipeable with either thumb.
      direction: DismissDirection.horizontal,
      background: SwipeBackground(
        alignment: Alignment.centerLeft,
        icon: chat.muted ? Icons.notifications_active : Icons.notifications_off,
        label: chat.muted ? 'Unmute' : 'Mute',
      ),
      secondaryBackground: SwipeBackground(
        alignment: Alignment.centerRight,
        icon: chat.pinned ? Icons.push_pin_outlined : Icons.push_pin,
        label: chat.pinned ? 'Unpin' : 'Pin',
        color: tg.accent,
      ),
      confirmDismiss: (direction) async {
        final db = ref.read(databaseProvider);
        if (direction == DismissDirection.startToEnd) {
          await db.setChatFlag(chat.jid, muted: !chat.muted);
        } else {
          await db.setChatFlag(chat.jid, pinned: !chat.pinned);
        }
        // Never actually remove the row: these actions change flags, and a
        // dismissed row that springs back looks like the app glitched.
        return false;
      },
      child: InkWell(
        onTap: onOpen,
        child: Container(
          height: TgDimens.chatsRowHeight,
          padding: const EdgeInsets.symmetric(
            horizontal: TgDimens.chatsHorizontalPadding,
          ),
          child: Row(
            children: [
              ContactAvatar(
                jid: chat.jid,
                title: title,
                hero: true,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (chat.pinned)
                          _Flag(icon: Icons.push_pin, color: tg.textSecondary),
                        if (chat.muted)
                          _Flag(
                            icon: Icons.notifications_off,
                            color: tg.textSecondary,
                          ),
                        if (locked)
                          _Flag(icon: Icons.lock, color: tg.accent),
                        Expanded(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: TgDimens.chatTitleFontSize,
                              fontWeight: chat.unreadCount > 0 && !chat.muted
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                              color: tg.textPrimary,
                            ),
                          ),
                        ),
                        // Before the time, as Telegram draws it: the badge is
                        // what the user is acting on and the time is context.
                        if (chat.unreadCount > 0) ...[
                          UnreadBadge(
                            count: chat.unreadCount,
                            muted: chat.muted,
                          ),
                          const SizedBox(width: 6),
                        ],
                        Text(
                          _timeOf(chat.lastActivity),
                          style: TextStyle(
                            fontSize: TgDimens.timeFontSize,
                            color: chat.unreadCount > 0 && !chat.muted
                                ? tg.accent
                                : tg.textSecondary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: TgDimens.chatsTitleGap),
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
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _timeOf(DateTime t) {
    final now = DateTime.now();
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    if (t.year == now.year && t.day == now.day) return '$h:$m';
    return '${t.day}/${t.month}';
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

/// The panel revealed behind a swiped row.
class SwipeBackground extends StatelessWidget {
  const SwipeBackground({
    super.key,
    required this.alignment,
    required this.icon,
    required this.label,
    this.color,
  });

  final Alignment alignment;
  final IconData icon;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final tint = color ?? context.tg.danger;
    final atStart = alignment == Alignment.centerLeft;
    return Container(
      color: tint,
      alignment: alignment,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Icon leads on the trailing side so it stays under the thumb as the
          // finger travels inward.
          if (!atStart) ...[
            Text(label, style: const TextStyle(color: Colors.white)),
            const SizedBox(width: 8),
          ],
          Icon(icon, color: Colors.white),
          if (atStart) ...[
            const SizedBox(width: 8),
            Text(label, style: const TextStyle(color: Colors.white)),
          ],
        ],
      ),
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