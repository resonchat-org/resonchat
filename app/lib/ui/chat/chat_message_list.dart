// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
// Transcript list for an open chat: day separators, unread divider, bubbles.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../crypto/omemo/track.dart';
import '../../l10n/l10n.dart';
import '../../state/providers.dart';
import '../../store/database.dart';
import '../../store/message_send_status.dart';
import '../../utils/appearance.dart';
import '../../xmpp/avatar.dart';
import '../../xmpp/muc.dart';
import '../../xmpp/reactions.dart';
import '../contact_avatar.dart';
import '../theme.dart';
import '../chats/unread.dart';
import 'chat_nicks.dart';
import 'message_bubble.dart';
import 'message_merge.dart';

/// Message list with day separators and an unread marker.
class ChatMessageList extends StatelessWidget {
  const ChatMessageList({
    super.key,
    required this.chatKey,
    required this.messages,
    required this.scroll,
    required this.onRetryDecrypt,
    required this.onReact,
    required this.onMenu,
    required this.onToggleSelected,
    required this.selectingMessageId,
    required this.onTextSelectionChanged,
    required this.onMentionNick,
    required this.onOccupantAvatarLongPress,
    required this.selectionMode,
    required this.selectedIds,
    required this.translations,
    required this.translatingIds,
    required this.readAt,
    required this.unreadCount,
    required this.unreadDividerKey,
    required this.focusMessageAnchor,
    required this.focusMessageKey,
    required this.bubbleStyle,
    required this.isGroup,
    required this.room,
    required this.highlightNicks,
  });

  final String chatKey;
  final List<Message> messages;
  final ScrollController scroll;
  final VoidCallback onRetryDecrypt;

  /// Toggling one emoji on one message. Takes the addressable id, because that
  /// is what a reaction refers to.
  final void Function(String targetId, String emoji) onReact;

  /// Long-press on one message. [anchor] is the row in global coordinates.
  final void Function(Message message, String body, Rect anchor) onMenu;

  /// Database id of the text message whose body is a live selection, or null.
  final int? selectingMessageId;

  /// Current selected slice of [selectingMessageId], including the full body
  /// when the selection first appears.
  final ValueChanged<String> onTextSelectionChanged;

  /// Toggling a message in the selection.
  final void Function(Message message) onToggleSelected;

  /// Conversations contact-picture tap → insert `nick:` / `, nick` in composer.
  final void Function(String nick) onMentionNick;

  /// Long-press occupant avatar → member action sheet (not message menu).
  final void Function(String nick) onOccupantAvatarLongPress;

  /// Whether the chat is in selection mode, so a tap selects rather than acts.
  final bool selectionMode;

  /// The stanza ids currently selected, in the order they were picked.
  final List<String> selectedIds;

  /// In-memory translations for this open chat (stanza id → text).
  final Map<String, String> translations;

  /// Stanza ids currently waiting on a Translate response.
  final Set<String> translatingIds;

  /// When the user last read this conversation, which is where the unread
  /// boundary goes.
  final DateTime? readAt;

  /// Badge count; used when the read marker alone cannot place a divider.
  final int unreadCount;

  /// Key the unread divider is built with, so the page can scroll to it.
  final GlobalKey unreadDividerKey;

  /// Search / deep-link target; when set, that row gets [focusMessageKey].
  final String? focusMessageAnchor;

  final GlobalKey focusMessageKey;

  /// Corner shape of the bubbles, from this conversation's appearance.
  final BubbleStyle bubbleStyle;

  /// MODE_MULTI: show occupant nicks above incoming bubbles.
  final bool isGroup;

  /// Live room roster (avatar real JID + nick validity for mentions).
  final GroupChat? room;

  /// Our nick / localpart for bolding @-highlights in body text.
  final List<String> highlightNicks;

  @override
  Widget build(BuildContext context) {
    if (messages.isEmpty) {
      return Center(child: Text(context.l10n.noMessagesYet));
    }

    final rows = <Widget>[];
    DateTime? lastDay;
    // The first message the user had not read when they last read this chat.
    // Null when everything here has been read, or when the marker is newer than
    // everything we hold (a chat read on another device) — in which case no
    // divider is drawn at all, because a divider with nothing above it is a
    // line across the top of an empty conversation.
    final firstUnread = firstUnreadId(
      messages,
      readAt,
      unreadCount: unreadCount,
    );
    bool unreadMarked = firstUnread == null;
    Message? previousBubble;
    var brokeMerge = false;

    for (final m in messages) {
      final day = DateTime(
        m.timestamp.year,
        m.timestamp.month,
        m.timestamp.day,
      );
      if (lastDay == null || day != lastDay) {
        rows.add(DateSeparator(date: m.timestamp));
        lastDay = day;
        brokeMerge = true;
      }
      // Drawn before the message, so it separates "read" from "not read" rather
      // than sitting under the last read one. The comparison is on the row's
      // own id rather than on a flag, because a MAM import can insert messages
      // in the middle and a one-shot flag would end up in the wrong place.
      if (!unreadMarked && matchesUnreadAnchor(m, firstUnread)) {
        rows.add(UnreadDivider(key: unreadDividerKey));
        unreadMarked = true;
        brokeMerge = true;
      }
      if (EncModeToken.parse(m.encMode) == EncModeToken.error) {
        Widget errorRow = ListTile(
          dense: true,
          leading: Icon(Icons.lock_outline, size: 18, color: context.tg.danger),
          title: Text(
            context.l10n.unableToDecrypt,
            style: TextStyle(
              fontStyle: FontStyle.italic,
              color: context.tg.textSecondary,
            ),
          ),
          trailing: TextButton(
            onPressed: onRetryDecrypt,
            child: Text(context.l10n.retry),
          ),
        );
        if (matchesUnreadAnchor(m, focusMessageAnchor)) {
          errorRow = KeyedSubtree(key: focusMessageKey, child: errorRow);
        }
        rows.add(errorRow);
        previousBubble = null;
        brokeMerge = false;
        continue;
      }
      // Conversations merge: hide avatar/nick on continuing rows; each message
      // stays its own bubble (we do not collapse bodies the way Conversations
      // can).
      final mergeChrome =
          !brokeMerge &&
          previousBubble != null &&
          messagesMergeAcrossList(previousBubble, m);
      brokeMerge = false;
      final cacheKey = m.stanzaId.isNotEmpty
          ? m.stanzaId
          : 'body:${m.body.hashCode}';
      Widget bubble = _ChatReactionBubble(
        chatKey: chatKey,
        message: m,
        selectionMode: selectionMode,
        selected: selectedIds.contains(m.stanzaId),
        bubbleStyle: bubbleStyle,
        isGroup: isGroup,
        room: room,
        highlightNicks: highlightNicks,
        showSenderChrome: !mergeChrome,
        translation: translations[cacheKey],
        translating: translatingIds.contains(cacheKey),
        onReact: (emoji) => onReact(m.stanzaId, emoji),
        onMenu: (body, anchor) => onMenu(m, body, anchor),
        textSelecting: selectingMessageId == m.id,
        onTextSelectionChanged: selectingMessageId == m.id
            ? onTextSelectionChanged
            : null,
        onToggleSelected: () => onToggleSelected(m),
        onMentionNick: onMentionNick,
        onOccupantAvatarLongPress: onOccupantAvatarLongPress,
      );
      if (matchesUnreadAnchor(m, focusMessageAnchor)) {
        bubble = KeyedSubtree(key: focusMessageKey, child: bubble);
      }
      rows.add(bubble);
      previousBubble = m;
    }

    return ListView(
      controller: scroll,
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: rows,
    );
  }
}

/// A bubble plus whatever reactions its message carries.
///
/// Split out so the chips can come from their own provider: they change
/// whenever anyone reacts, which is independent of the message list rebuilding.
class _ChatReactionBubble extends ConsumerWidget {
  const _ChatReactionBubble({
    required this.chatKey,
    required this.message,
    required this.selectionMode,
    required this.selected,
    required this.bubbleStyle,
    required this.isGroup,
    required this.room,
    required this.highlightNicks,
    required this.showSenderChrome,
    this.translation,
    this.translating = false,
    required this.onReact,
    required this.onMenu,
    required this.onToggleSelected,
    required this.textSelecting,
    this.onTextSelectionChanged,
    required this.onMentionNick,
    required this.onOccupantAvatarLongPress,
  });

  final String chatKey;
  final Message message;
  final bool selectionMode;
  final bool selected;
  final BubbleStyle bubbleStyle;
  final bool isGroup;
  final GroupChat? room;
  final List<String> highlightNicks;

  /// False when this row continues a Conversations merge group — hide nick
  /// and avatar, but keep the avatar gutter so bubbles stay aligned.
  final bool showSenderChrome;
  final String? translation;
  final bool translating;
  final void Function(String emoji) onReact;
  final void Function(String body, Rect anchor) onMenu;
  final bool textSelecting;
  final ValueChanged<String>? onTextSelectionChanged;
  final void Function() onToggleSelected;
  final void Function(String nick) onMentionNick;
  final void Function(String nick) onOccupantAvatarLongPress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Keyed on the stored id, which is the origin-id when the sender published
    // one. Empty means the message cannot be addressed, so it is drawn without
    // chips rather than with chips nobody could add to.
    final targetId = message.stanzaId;
    final reactions = targetId.isEmpty
        ? const <ReactionGroup>[]
        : ref
                  .watch(
                    reactionGroupsProvider((
                      chatKey: chatKey,
                      targetId: targetId,
                    )),
                  )
                  .value ??
              const [];
    final nick = isGroup && message.incoming
        ? occupantNick(message.sender)
        : null;
    // Null when merged into the previous row — hide nick + avatar only.
    final chromeNick = showSenderChrome ? nick : null;
    final realJid = chromeNick == null
        ? null
        : occupantRealJid(room, chromeNick);
    // Prefer real bare JID (PEP); else room/nick for occupant vCard (Gajim).
    final avatar = chromeNick == null
        ? null
        : _BubbleOccupantAvatar(
            nick: chromeNick,
            realJid: realJid,
            roomJid: room?.roomJid,
            colorKey: message.sender,
          );
    return MessageBubble(
      text: message.body,
      time: message.timestamp,
      side: message.incoming ? BubbleSide.incoming : BubbleSide.outgoing,
      senderName: chromeNick,
      senderColor: chromeNick == null ? null : nickColor(chromeNick),
      delivered: message.delivered,
      displayed: message.displayed,
      failed:
          message.sendStatus == MessageSendStatus.sendFailed ||
          message.deliveryError.isNotEmpty,
      sendStatus: message.sendStatus,
      // What the message actually used, from what the sender declared — not
      // what we would have chosen. Read back from the row rather than
      // recomputed, so the label survives a change of mind afterwards.
      track: EncModeToken.parse(message.encMode).track ?? Track.none,
      reactions: reactions,
      retracted: message.retracted,
      edited: message.editedAt != null,
      mine: !message.incoming,
      selected: selected,
      selectionMode: selectionMode,
      bubbleStyle: bubbleStyle,
      message: message,
      chatKey: chatKey,
      mentionsMe: message.mentionsMe,
      highlightNicks: isGroup ? highlightNicks : const [],
      translation: translation,
      translating: translating,
      // Group incoming always reserves the avatar column so merged rows align.
      reserveAvatarGutter: isGroup && message.incoming,
      leadingAvatar: avatar,
      onAvatarTap: chromeNick == null || selectionMode
          ? null
          : () => onMentionNick(chromeNick),
      onAvatarLongPress: chromeNick == null || selectionMode
          ? null
          : () => onOccupantAvatarLongPress(chromeNick),
      onReact: onReact,
      textSelecting: textSelecting,
      onTextSelectionChanged: onTextSelectionChanged,
      // Long-press → context menu (incl. Select). Tap toggles only while
      // already in multi-select — Select from the menu is what enters it.
      onLongPress: message.retracted
          ? null
          : selectionMode
          ? (message.stanzaId.isEmpty ? null : (_) => onToggleSelected())
          : (anchor) => onMenu(message.body, anchor),
      onTap: message.retracted || !selectionMode || message.stanzaId.isEmpty
          ? null
          : onToggleSelected,
    );
  }
}

/// Avatar beside a group bubble.
///
/// Real bare JID → PEP; otherwise `room/nick` → occupant vCard (Gajim
/// GroupchatParticipant). [contactAvatarProvider] must not bare occupant JIDs.
class _BubbleOccupantAvatar extends StatelessWidget {
  const _BubbleOccupantAvatar({
    required this.nick,
    required this.colorKey,
    this.realJid,
    this.roomJid,
  });

  final String nick;
  final String colorKey;
  final String? realJid;
  final String? roomJid;

  static const double radius = 18;

  @override
  Widget build(BuildContext context) {
    final real = realJid?.trim();
    if (real != null && real.isNotEmpty) {
      return ContactAvatar(jid: real, title: nick, radius: radius);
    }
    final room = roomJid?.trim();
    if (room != null && room.isNotEmpty) {
      return ContactAvatar(jid: '$room/$nick', title: nick, radius: radius);
    }
    final tg = context.tg;
    final colour = tintFor(colorKey, tg.accent);
    return CircleAvatar(
      radius: radius,
      backgroundColor: colour.withValues(alpha: 0.22),
      child: Text(
        avatarInitial(nick, colorKey),
        style: TextStyle(
          color: colour,
          fontSize: radius * 0.8,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}
