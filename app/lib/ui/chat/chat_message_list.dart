// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
// Transcript list for an open chat: day separators, unread divider, bubbles.

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:resonchat/crypto/dual/track.dart';
import 'package:resonchat/l10n/l10n.dart';
import 'package:resonchat/persistence/database.dart';
import 'package:resonchat/state/providers.dart';
import 'package:resonchat/ui/chat/appearance.dart';
import 'package:resonchat/ui/chat/chat_nicks.dart';
import 'package:resonchat/ui/chat/message_bubble.dart';
import 'package:resonchat/ui/chat/message_merge.dart';
import 'package:resonchat/ui/chat/read_ring.dart';
import 'package:resonchat/ui/chat/reply_quote.dart';
import 'package:resonchat/ui/chat/transcript_rows.dart';
import 'package:resonchat/ui/chats/unread.dart';
import 'package:resonchat/ui/contact_avatar.dart';
import 'package:resonchat/ui/motion.dart';
import 'package:resonchat/ui/theme.dart';
import 'package:resonchat/xmpp/chat/reactions.dart';
import 'package:resonchat/xmpp/group_read.dart';
import 'package:resonchat/xmpp/message_send_status.dart';
import 'package:resonchat/xmpp/muc/muc.dart';
import 'package:resonchat/xmpp/roster/avatar.dart';

/// Message list with day separators and an unread marker.
class ChatMessageList extends StatefulWidget {
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
    this.incomingTranslations = const {},
    this.outgoingOriginals = const {},
    required this.translatingIds,
    required this.readAt,
    required this.unreadCount,
    required this.unreadDividerKey,
    required this.focusMessageAnchor,
    required this.focusMessageKey,
    this.highlightMessageAnchor,
    required this.onReplyTap,
    required this.onForwardTap,
    required this.bubbleStyle,
    required this.isGroup,
    required this.groupReads,
    required this.room,
    required this.highlightNicks,
    required this.peerName,
    required this.selfNick,
    this.loadingOlder = false,
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

  /// XEP-0171 text already on a stanza, keyed by stanza id.
  ///
  /// Shown without a long-press when the language matches the UI. On a
  /// message this device replaced before sending, the local original wins.
  /// A manual translation in [translations] wins over both.
  final Map<String, String> incomingTranslations;

  /// Original text of a message this device replaced before sending.
  ///
  /// The bubble is the translation that went out. This line sits where a
  /// translation of somebody else's message would sit.
  final Map<String, String> outgoingOriginals;

  /// Stanza ids currently waiting on a Translate response.
  final Set<String> translatingIds;

  /// When the user last read this conversation, which is where the unread
  /// boundary goes.
  final DateTime? readAt;

  /// Badge count; used when the read marker alone cannot place a divider.
  final int unreadCount;

  /// Key the unread divider is built with, so the page can scroll to it.
  final GlobalKey unreadDividerKey;

  /// Search / deep-link / reply-jump target; when set, that row gets
  /// [focusMessageKey].
  final String? focusMessageAnchor;

  final GlobalKey focusMessageKey;

  /// Brief flash after jumping here from a reply card (monocles highlight).
  final String? highlightMessageAnchor;

  /// Tap an in-bubble reply card → jump to the quoted message id.
  final void Function(String replyToId) onReplyTap;

  /// Tap a forward card → open/join origin; [roomStanzaId] only for MUC jump.
  final void Function(String forwardFromJid, String roomStanzaId) onForwardTap;

  /// Corner shape of the bubbles, from this conversation's appearance.
  final BubbleStyle bubbleStyle;

  /// MODE_MULTI: show occupant nicks above incoming bubbles.
  final bool isGroup;

  /// Private and non-anonymous: draw the read ring and record readers.
  final bool groupReads;

  /// Live room roster (avatar real JID + nick validity for mentions).
  final GroupChat? room;

  /// Our nick / localpart for bolding @-highlights in body text.
  final List<String> highlightNicks;

  /// 1:1 display name, used when they retract a message.
  final String peerName;

  /// Our room nick, so a moderation we issued reads as "you".
  final String selfNick;

  /// Spinner above the oldest row while an older MAM page is in flight.
  final bool loadingOlder;

  @override
  State<ChatMessageList> createState() => _ChatMessageListState();
}

class _ChatMessageListState extends State<ChatMessageList> {
  /// Message ids already present. Used to find the rows that are genuinely new
  /// rather than merely rebuilt (a status tick, a reaction, a translation).
  final Set<String> _known = <String>{};
  Set<String> _entering = <String>{};
  bool _seeded = false;

  /// Newest timestamp seen, so loading older history above the viewport does
  /// not make every restored row slide in.
  DateTime? _latest;

  static String _idOf(Message m) => 'row-${m.id}';

  Widget _entrance(Message m, Widget child) {
    final id = _idOf(m);
    return _MessageEntrance(
      key: ValueKey('message-entrance-$id'),
      animate: _entering.contains(id),
      child: child,
    );
  }

  @override
  void initState() {
    super.initState();
    if (widget.messages.isNotEmpty) _seed();
  }

  void _seed({bool animate = false}) {
    _seeded = true;
    _known.addAll(widget.messages.map(_idOf));
    if (widget.messages.isNotEmpty) {
      _latest = widget.messages.last.timestamp;
    }
    if (animate) {
      _entering = widget.messages.map(_idOf).toSet();
      _scheduleEntranceClear();
    }
  }

  /// Forget an entrance after the frame that started it.
  ///
  /// Otherwise a row that is disposed and rebuilt later (scrolled out and
  /// back) still carries `animate: true` and replays the slide.
  void _scheduleEntranceClear() {
    final scheduled = _entering;
    if (scheduled.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !identical(_entering, scheduled)) return;
      _entering = const <String>{};
    });
  }

  @override
  void didUpdateWidget(covariant ChatMessageList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.chatKey != widget.chatKey) {
      // Normally the page carries a key per chat, but do not inherit another
      // conversation's ids if that ever changes.
      _known.clear();
      _entering = const <String>{};
      _latest = null;
      _seeded = false;
      if (widget.messages.isNotEmpty) {
        _seed();
      } else {
        _seeded = true;
      }
      return;
    }
    if (!_seeded) {
      if (widget.messages.isEmpty) {
        _seeded = true;
        return;
      }
      // The list was empty when it was built, so this is the first message of
      // a new conversation, not restored history: let it arrive like every
      // later one.
      _seed(animate: true);
      return;
    }
    final fresh = <String>{};
    for (final m in widget.messages) {
      final id = _idOf(m);
      if (!_known.add(id)) continue;
      if (_latest == null || !m.timestamp.isBefore(_latest!)) fresh.add(id);
    }
    var newest = _latest;
    for (final m in widget.messages) {
      if (newest == null || m.timestamp.isAfter(newest)) newest = m.timestamp;
    }
    _latest = newest;
    _entering = fresh;
    _scheduleEntranceClear();
  }

  /// Prior bubble for merge chrome, or null when a separator broke the group.
  Message? _previousBubbleForMerge(List<TranscriptRow> rows, int index) {
    for (var i = index - 1; i >= 0; i--) {
      final row = rows[i];
      if (row.kind == TranscriptRowKind.date ||
          row.kind == TranscriptRowKind.unread ||
          row.kind == TranscriptRowKind.loadingOlder) {
        return null;
      }
      if (row.kind == TranscriptRowKind.message) {
        final m = row.message!;
        if (m.retracted ||
            EncModeToken.parse(m.encMode) == EncModeToken.error) {
          return null;
        }
        return m;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final messages = widget.messages;
    if (messages.isEmpty) {
      return Center(child: Text(context.l10n.noMessagesYet));
    }

    final rows = buildTranscriptRows(
      messages,
      readAt: widget.readAt,
      unreadCount: widget.unreadCount,
      loadingOlder: widget.loadingOlder,
    );

    // Reply cards name the quoted message, so keep the rows we can resolve by
    // the id `replyTo` points at (origin-id or, for older rows, the room id).
    final quotedById = <String, Message>{};
    for (final m in messages) {
      if (m.stanzaId.isNotEmpty) quotedById[m.stanzaId] = m;
      if (m.roomStanzaId.isNotEmpty) quotedById[m.roomStanzaId] = m;
    }

    final selfLabel = widget.selfNick.isNotEmpty
        ? widget.selfNick
        : context.l10n.you;

    // reverse: index 0 = newest (visual bottom). Ascending [rows] are mapped
    // with length-1-i so open paints from the latest end immediately.
    return ListView.builder(
      controller: widget.scroll,
      reverse: true,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: rows.length,
      itemBuilder: (context, index) {
        final ascendingIndex = rows.length - 1 - index;
        final row = rows[ascendingIndex];
        switch (row.kind) {
          case TranscriptRowKind.loadingOlder:
            return const Padding(
              key: ValueKey('transcript-loading-older'),
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Center(
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            );
          case TranscriptRowKind.date:
            return DateSeparator(
              key: ValueKey('date-${row.date!.toIso8601String()}'),
              date: row.date!,
            );
          case TranscriptRowKind.unread:
            return UnreadDivider(key: widget.unreadDividerKey);
          case TranscriptRowKind.message:
            final m = row.message!;
            return KeyedSubtree(
              key: ValueKey(
                m.stanzaId.isNotEmpty ? 'msg-${m.stanzaId}' : 'msg-db-${m.id}',
              ),
              child: _buildMessageRow(
                context,
                m: m,
                previousBubble: _previousBubbleForMerge(rows, ascendingIndex),
                quotedById: quotedById,
                selfLabel: selfLabel,
              ),
            );
        }
      },
    );
  }

  Widget _buildMessageRow(
    BuildContext context, {
    required Message m,
    required Message? previousBubble,
    required Map<String, Message> quotedById,
    required String selfLabel,
  }) {
    final focusMessageAnchor = widget.focusMessageAnchor;
    final focusMessageKey = widget.focusMessageKey;
    final isGroup = widget.isGroup;
    final peerName = widget.peerName;
    final selfNick = widget.selfNick;
    final chatKey = widget.chatKey;

    if (m.retracted) {
      Widget line = RetractedNotice(
        message: m,
        chatKey: chatKey,
        label: _retractionLabel(
          context.l10n,
          message: m,
          isGroup: isGroup,
          peerName: peerName,
          selfNick: selfNick,
        ),
      );
      if (matchesFocusAnchor(m, focusMessageAnchor)) {
        line = KeyedSubtree(key: focusMessageKey, child: line);
      }
      return _entrance(m, line);
    }

    if (EncModeToken.parse(m.encMode) == EncModeToken.error) {
      Widget errorRow = ListTile(
        dense: true,
        leading: Icon(Icons.lock_outline, size: 18, color: context.appColors.danger),
        title: Text(
          context.l10n.unableToDecrypt,
          style: TextStyle(
            fontStyle: FontStyle.italic,
            color: context.appColors.textSecondary,
          ),
        ),
        trailing: TextButton(
          onPressed: widget.onRetryDecrypt,
          child: Text(context.l10n.retry),
        ),
      );
      if (matchesFocusAnchor(m, focusMessageAnchor)) {
        errorRow = KeyedSubtree(key: focusMessageKey, child: errorRow);
      }
      return _entrance(m, errorRow);
    }

    final mergeChrome =
        previousBubble != null && messagesMergeAcrossList(previousBubble, m);
    final cacheKey = m.stanzaId.isNotEmpty
        ? m.stanzaId
        : 'body:${m.body.hashCode}';
    final reply = m.replyTo.isEmpty
        ? ReplyPresentation(body: m.body, quote: '', author: '')
        : replyPresentation(
            m,
            quoted: quotedById[m.replyTo],
            isGroup: isGroup,
            peerName: peerName,
            selfLabel: selfLabel,
          );
    final hasForward = m.forwardBody.trim().isNotEmpty;
    Widget bubble = _ChatReactionBubble(
      chatKey: chatKey,
      message: m,
      text: hasForward ? m.body : reply.body,
      replyBody: hasForward ? '' : reply.quote,
      replyAuthor: hasForward ? '' : reply.author,
      forwardFromJid: hasForward ? m.forwardFromJid : '',
      forwardAuthor: hasForward ? m.forwardAuthor : '',
      forwardBody: hasForward ? m.forwardBody : '',
      forwardOriginId: hasForward ? m.forwardOriginId : '',
      selectionMode: widget.selectionMode,
      selected: widget.selectedIds.contains(m.stanzaId),
      highlighted: matchesFocusAnchor(m, widget.highlightMessageAnchor),
      bubbleStyle: widget.bubbleStyle,
      isGroup: isGroup,
      groupReads: widget.groupReads,
      room: widget.room,
      highlightNicks: widget.highlightNicks,
      showSenderChrome: !mergeChrome,
      translation:
          widget.translations[cacheKey] ??
          (m.incoming
              ? widget.incomingTranslations[m.stanzaId]
              : widget.outgoingOriginals[m.stanzaId] ??
                    widget.incomingTranslations[m.stanzaId]),
      translating: widget.translatingIds.contains(cacheKey),
      onReact: (emoji) => widget.onReact(m.stanzaId, emoji),
      onMenu: (body, anchor) => widget.onMenu(m, body, anchor),
      onReplyTap: widget.selectionMode || hasForward
          ? null
          : () => widget.onReplyTap(m.replyTo),
      onForwardTap: widget.selectionMode || !hasForward
          ? null
          : () => widget.onForwardTap(m.forwardFromJid, m.forwardOriginId),
      textSelecting: widget.selectingMessageId == m.id,
      onTextSelectionChanged: widget.selectingMessageId == m.id
          ? widget.onTextSelectionChanged
          : null,
      onToggleSelected: () => widget.onToggleSelected(m),
      onMentionNick: widget.onMentionNick,
      onOccupantAvatarLongPress: widget.onOccupantAvatarLongPress,
    );
    if (matchesFocusAnchor(m, focusMessageAnchor)) {
      bubble = KeyedSubtree(key: focusMessageKey, child: bubble);
    }
    return _entrance(m, bubble);
  }
}

/// Fades and lifts one message the first time it appears.
///
/// Only rows that actually arrived while the chat was open are [animate]d;
/// rebuilding for a reaction or a receipt does not restart it, and rows that
/// scroll back into view after being disposed stay put.
class _MessageEntrance extends StatefulWidget {
  const _MessageEntrance({
    super.key,
    required this.animate,
    required this.child,
  });

  final bool animate;
  final Widget child;

  @override
  State<_MessageEntrance> createState() => _MessageEntranceState();
}

class _MessageEntranceState extends State<_MessageEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: kMotionBase,
    value: 1,
  );
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (!widget.animate || reduceMotion) return;
    _controller.value = 0;
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (context, child) {
        final t = kMotionStandard.transform(_controller.value);
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, 7 * (1 - t)),
            child: child,
          ),
        );
      },
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
    required this.text,
    required this.replyBody,
    required this.replyAuthor,
    this.forwardFromJid = '',
    this.forwardAuthor = '',
    this.forwardBody = '',
    this.forwardOriginId = '',
    required this.selectionMode,
    required this.selected,
    this.highlighted = false,
    required this.bubbleStyle,
    required this.isGroup,
    required this.groupReads,
    required this.room,
    required this.highlightNicks,
    required this.showSenderChrome,
    this.translation,
    this.translating = false,
    required this.onReact,
    required this.onMenu,
    this.onReplyTap,
    this.onForwardTap,
    required this.onToggleSelected,
    required this.textSelecting,
    this.onTextSelectionChanged,
    required this.onMentionNick,
    required this.onOccupantAvatarLongPress,
  });

  final String chatKey;
  final Message message;

  /// The bubble text after removing the reply's leading quote block.
  final String text;

  /// Quote text for the reply card. May come from the body fallback or the
  /// row's stored copy when a target is gone.
  final String replyBody;

  /// Display name of the quoted message's author.
  final String replyAuthor;

  final String forwardFromJid;
  final String forwardAuthor;
  final String forwardBody;
  final String forwardOriginId;

  final bool selectionMode;
  final bool selected;
  final bool highlighted;
  final BubbleStyle bubbleStyle;
  final bool isGroup;
  final bool groupReads;
  final GroupChat? room;
  final List<String> highlightNicks;

  /// False when this row continues a Conversations merge group — hide nick
  /// and avatar, but keep the avatar gutter so bubbles stay aligned.
  final bool showSenderChrome;
  final String? translation;
  final bool translating;
  final void Function(String emoji) onReact;
  final void Function(String body, Rect anchor) onMenu;
  final VoidCallback? onReplyTap;
  final VoidCallback? onForwardTap;
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
    final onWire =
        !message.incoming &&
        !message.retracted &&
        (message.sendStatus == MessageSendStatus.send ||
            message.sendStatus == MessageSendStatus.sendReceived ||
            message.sendStatus == MessageSendStatus.sendDisplayed);
    double? readFraction;
    VoidCallback? onReadRing;
    if (onWire && !isGroup) {
      readFraction =
          message.displayed ||
              message.sendStatus == MessageSendStatus.sendDisplayed
          ? 1
          : 0;
    } else if (onWire && groupReads) {
      final readers = decodeReadBy(message.readBy);
      final selfBare = ref.watch(myBareJidProvider).value;
      final split = splitGroupReads(
        occupants: room?.occupants ?? const [],
        selfNick: room?.nick ?? '',
        selfBareJid: selfBare,
        readJids: readers,
      );
      final total = split.read.length + split.unread.length;
      readFraction = total == 0 ? 0 : split.read.length / total;
      onReadRing = () {
        unawaited(
          showGroupReadSheet(
            context,
            roomJid: room?.roomJid ?? '',
            read: split.read,
            unread: split.unread,
          ),
        );
      };
    }
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
      text: text,
      time: message.timestamp,
      side: message.incoming ? BubbleSide.incoming : BubbleSide.outgoing,
      senderName: chromeNick,
      senderColor: chromeNick == null ? null : nickColor(chromeNick),
      delivered: message.delivered,
      displayed: message.displayed,
      readFraction: readFraction,
      onReadRing: onReadRing,
      failed:
          message.sendStatus == MessageSendStatus.sendFailed ||
          message.deliveryError.isNotEmpty,
      sendStatus: message.sendStatus,
      encMode: EncModeToken.forBubble(
        message.encMode,
        incoming: message.incoming,
      ),
      reactions: reactions,
      retracted: message.retracted,
      edited: message.editedAt != null,
      mine: !message.incoming,
      selected: selected,
      highlighted: highlighted,
      selectionMode: selectionMode,
      bubbleStyle: bubbleStyle,
      message: message,
      chatKey: chatKey,
      replyTo: message.replyTo,
      replyBody: replyBody,
      replyAuthor: replyAuthor,
      onReplyTap: onReplyTap,
      forwardFromJid: forwardFromJid,
      forwardAuthor: forwardAuthor,
      forwardBody: forwardBody,
      onForwardTap: onForwardTap,
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
      onMenu: message.retracted
          ? null
          : selectionMode
          ? (message.stanzaId.isEmpty ? null : (_) => onToggleSelected())
          : (anchor) => onMenu(
              text.trim().isNotEmpty
                  ? text
                  : (forwardBody.isNotEmpty ? forwardBody : text),
              anchor,
            ),
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
    final tg = context.appColors;
    final colour = tintFor(colorKey, tg.accent);
    return CircleAvatar(
      radius: radius,
      backgroundColor: avatarFill(colour),
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

/// Self-retraction stays "you / they retracted a message". A moderator
/// retracting someone else names both people.
String _retractionLabel(
  AppLocalizations l10n, {
  required Message message,
  required bool isGroup,
  required String peerName,
  required String selfNick,
}) {
  final authorIsMe = !message.incoming;
  final author = authorIsMe
      ? ''
      : (isGroup ? (occupantNick(message.sender) ?? message.sender) : peerName);
  final moderated = message.retractedBy.isNotEmpty;
  if (!moderated) {
    return authorIsMe
        ? l10n.youRetractedMessage
        : l10n.peerRetractedMessage(author);
  }
  final actor = message.retractedBy;
  final actorIsMe = selfNick.isNotEmpty && actor == selfNick;
  final samePerson = authorIsMe ? actorIsMe : actor == author;
  final String notice;
  if (samePerson) {
    notice = actorIsMe
        ? l10n.youRetractedMessage
        : l10n.peerRetractedMessage(actor);
  } else if (actorIsMe) {
    notice = l10n.youRetractedTheirs(author);
  } else if (authorIsMe) {
    notice = l10n.peerRetractedYours(actor);
  } else {
    notice = l10n.peerRetractedTheirs(actor, author);
  }
  final reason = message.retractedReason.trim();
  if (reason.isEmpty) return notice;
  return l10n.retractionWithReason(notice, reason);
}
