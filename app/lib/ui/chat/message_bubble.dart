// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Chat bubble translated from Telegram for Android's `ChatMessageCell`
// (GPL-2.0-or-later): rounded body with a corner tail, timestamp sitting
// on the same baseline as the text, and read receipts. Colours come from
// the theme; no Telegram assets are bundled.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../crypto/omemo/track.dart';
import '../../store/database.dart';
import '../../xmpp/reactions.dart';
import '../../xmpp/retraction.dart';
import '../../utils/appearance.dart';
import 'media_attachment.dart';
import 'mention_text.dart';
import '../theme.dart';

enum BubbleSide { incoming, outgoing }

/// Hide the raw share URL when the media chrome already represents the file.
bool _shouldHideUrlBody(Message? message, String text) {
  if (message == null || message.mediaUrl.isEmpty) return false;
  return text.trim() == message.mediaUrl.trim() ||
      text.trim().split('\n').first.trim() == message.mediaUrl.trim();
}

/// Paints a rounded rectangle whose one corner is squared off, forming the
/// tail that points at the sender.
class _BubblePainter extends CustomPainter {
  _BubblePainter({
    required this.color,
    required this.side,
    required this.radius,
    required this.tail,
    required this.style,
  });

  final Color color;
  final BubbleSide side;
  final double radius;
  final double tail;
  final BubbleStyle style;

  @override
  void paint(Canvas canvas, Size size) {
    final mine = side == BubbleSide.outgoing;
    // A square bubble has no tail: the point of that style is a flat, system-like
    // row, and leaving a tail on it looks like a bug rather than a choice.
    final tailSize = style == BubbleStyle.square ? 0.0 : tail;
    final radii = bubbleRadii(style, mine);

    final path = Path();
    if (mine) {
      // Tail at bottom-right. The two corners on the right take the "rounded"
      // radius and the two on the left the "square" one, so the pointed corner
      // is the one nearest the other party.
      final rt = radii.topRight.x;
      final lt = radii.topLeft.x;
      path
        ..moveTo(lt, 0)
        ..lineTo(size.width - rt, 0)
        ..arcToPoint(Offset(size.width, rt), radius: Radius.circular(rt))
        ..lineTo(size.width, size.height - tailSize)
        ..lineTo(size.width - tailSize, size.height)
        ..lineTo(radii.bottomLeft.x, size.height)
        ..lineTo(0, radii.bottomLeft.x)
        ..arcToPoint(Offset(lt, 0), radius: Radius.circular(lt))
        ..close();
    } else {
      // Mirror of the outgoing path: tail at bottom-left.
      final rt = radii.topRight.x;
      final lt = radii.topLeft.x;
      final br = radii.bottomRight.x;
      path
        ..moveTo(lt, 0)
        ..lineTo(size.width - rt, 0)
        ..arcToPoint(Offset(size.width, rt), radius: Radius.circular(rt))
        ..lineTo(size.width, size.height - br)
        ..lineTo(size.width - br, size.height)
        ..lineTo(tailSize, size.height)
        ..lineTo(0, size.height - tailSize)
        ..lineTo(0, lt)
        ..arcToPoint(Offset(lt, 0), radius: Radius.circular(lt))
        ..close();
    }

    canvas.drawShadow(
      path.shift(const Offset(0, 1)),
      Colors.black26,
      1.5,
      true,
    );
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_BubblePainter old) =>
      old.color != color ||
      old.side != side ||
      old.radius != radius ||
      old.tail != tail ||
      old.style != style;
}

/// One message row: optional sender name (group chats), the bubble, and
/// the delivery/receipt ticks.
class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.text,
    required this.time,
    required this.side,
    this.senderName,
    this.senderColor,
    this.delivered = false,
    this.displayed = false,
    this.failed = false,
    this.track = Track.none,
    this.reactions = const [],
    this.retracted = false,
    this.edited = false,
    this.selected = false,
    this.selectionMode = false,
    this.bubbleStyle = BubbleStyle.rounded,
    this.mine = false,
    this.replyTo = '',
    this.replyBody = '',
    this.replyAuthor = '',
    this.message,
    this.chatKey,
    this.mentionsMe = false,
    this.highlightNicks = const [],
    this.onReact,
    this.onLongPress,
    this.onTap,
  });

  final String text;

  /// When set and carrying a media URL, render download / image UI.
  final Message? message;

  /// Owning conversation key ([ChatRef.key]) for media download / DB writes.
  final String? chatKey;

  /// This inbound group message addressed us (nick / MUC PM).
  ///
  /// Draws a soft accent tint on the bubble (Telegram flashes selection on
  /// unread mentions; we keep a light persistent tint so the row stays
  /// recognizable after the flash would have ended) and bolds matched nicks.
  final bool mentionsMe;

  /// Our nick / localpart used to bold highlight spans in [text].
  final List<String> highlightNicks;

  final DateTime time;
  final BubbleSide side;

  /// Which track this message actually travelled on.
  ///
  /// Defaults to [Track.none] rather than being required: a bubble that
  /// forgets to say so would then claim "no encryption" for a message that
  /// was encrypted, which is the one mistake this label must never make.
  final Track track;

  /// Reaction chips to draw under the bubble (XEP-0444).
  final List<ReactionGroup> reactions;

  /// Tapping a chip toggles it; offered the whole quick set for a new one.
  final void Function(String emoji)? onReact;

  /// True once the sender retracted this message (XEP-0424).
  final bool retracted;

  /// True once this message was corrected (XEP-0308).
  final bool edited;

  /// Whether we sent it. Decides the wording of the retracted placeholder: the
  /// person who hit "delete" is the only one who can tell that it worked.
  final bool mine;

  /// This message is part of the current selection.
  final bool selected;

  /// Corner shape, from this conversation's appearance setting.
  final BubbleStyle bubbleStyle;

  /// The chat is in selection mode.
  ///
  /// A tap means "select" rather than "open", which is the whole reason the
  /// mode exists — and the reason a selected bubble still has to be drawn, since
  /// the user needs to see what they picked.
  final bool selectionMode;

  /// Origin-id of the message this one replies to, or empty.
  final String replyTo;

  /// The quoted text, copied onto this row rather than looked up.
  ///
  /// Copied because the quoted message is the one most likely to disappear: a
  /// retraction is one tap away, and a quote that empties out the moment its
  /// target is deleted leaves the reader with "replying to" and nothing under
  /// it.
  final String replyBody;

  /// Nickname of the quoted message's author.
  final String replyAuthor;

  /// Shown above the bubble in group chats, tinted per sender.
  final String? senderName;
  final Color? senderColor;

  /// True once a delivery receipt arrived (XEP-0184).
  final bool delivered;

  /// True once a read marker arrived (XEP-0333 `<displayed/>`).
  final bool displayed;

  final bool failed;

  final VoidCallback? onLongPress;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tg = context.tg;
    final mine = this.mine || side == BubbleSide.outgoing;
    final baseColor = mine ? tg.ownBubble : tg.peerBubble;
    // Soft accent wash when this message @'d us — enough to find it in a
    // scroll, not a second selection colour fighting [selected].
    final color = mentionsMe && !mine
        ? Color.alphaBlend(tg.accent.withValues(alpha: 0.14), baseColor)
        : baseColor;
    final bodyStyle = TextStyle(
      fontSize: TgDimens.messageFontSize,
      color: tg.textPrimary,
      height: 1.3,
    );

    return Container(
      // The selection tint is on the row, not the bubble: tinting the bubble
      // itself would hide the text it is tinting behind the highlight.
      color: selected
          ? Theme.of(context).colorScheme.primaryContainer
                .withValues(alpha: 0.5)
          : null,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Column(
        crossAxisAlignment: mine
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          if (senderName != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 2, left: 12, right: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (mentionsMe) ...[
                    Icon(Icons.alternate_email, size: 14, color: tg.accent),
                    const SizedBox(width: 4),
                  ],
                  Text(
                    senderName!,
                    style: TextStyle(
                      fontSize: 13,
                      color: senderColor ?? tg.accent,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          if (replyTo.isNotEmpty && !retracted)
            _ReplyQuote(body: replyBody, author: replyAuthor),
          GestureDetector(
            onTap: onTap,
            onLongPress: onLongPress,
            child: CustomPaint(
              painter: _BubblePainter(
                color: color,
                side: side,
                radius: TgDimens.bubbleRadius,
                tail: TgDimens.bubbleTailSize,
                style: bubbleStyle,
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  TgDimens.bubblePaddingH + 4,
                  TgDimens.bubblePaddingV,
                  TgDimens.bubblePaddingH + 4,
                  TgDimens.bubblePaddingV,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!retracted &&
                        message != null &&
                        message!.mediaUrl.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: MediaAttachment(
                          message: message!,
                          chatKey: chatKey,
                        ),
                      ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Flexible(
                          child: retracted
                              ? Text(
                                  mine
                                      ? kRetractedNoticeMine
                                      : kRetractedNotice,
                                  style: TextStyle(
                                    fontSize: TgDimens.messageFontSize,
                                    fontStyle: FontStyle.italic,
                                    color: tg.textSecondary,
                                    height: 1.3,
                                  ),
                                )
                              : _shouldHideUrlBody(message, text)
                              ? const SizedBox.shrink()
                              : Text.rich(
                                  mentionAwareSpan(
                                    text,
                                    style: bodyStyle,
                                    highlightNicks: highlightNicks,
                                    mentionStyle: bodyStyle.copyWith(
                                      fontWeight: FontWeight.w700,
                                      color: tg.accent,
                                    ),
                                  ),
                                ),
                        ),
                        if (edited && !retracted)
                          Padding(
                            padding: const EdgeInsets.only(left: 6, bottom: 2),
                            child: Text(
                              context.l10n.edited,
                              style: TextStyle(
                                fontSize: TgDimens.timeFontSize - 1,
                                color: tg.textSecondary,
                              ),
                            ),
                          ),
                        const SizedBox(width: 8),
                        _MetaRow(
                          time: time,
                          delivered: delivered,
                          displayed: displayed,
                          failed: failed,
                          mine: mine,
                          track: track,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (reactions.isNotEmpty && !retracted)
            Padding(
              padding: EdgeInsets.only(
                top: 3,
                left: mine ? 0 : 10,
                right: mine ? 10 : 0,
              ),
              child: Wrap(
                spacing: 4,
                runSpacing: 4,
                alignment: mine ? WrapAlignment.end : WrapAlignment.start,
                children: [
                  for (final reaction in reactions)
                    ReactionChip(
                      reaction: reaction,
                      onTap: onReact == null
                          ? null
                          : () => onReact!(reaction.emoji),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// The quoted block drawn above a reply.
///
/// The quote sits *outside* the bubble, above it, the way Telegram and
/// Conversations both draw it: it is not part of what was said, and putting it
/// inside would make the reply look longer than it is.
class _ReplyQuote extends StatelessWidget {
  const _ReplyQuote({required this.body, required this.author});

  final String body;
  final String author;

  @override
  Widget build(BuildContext context) {
    final tg = context.tg;
    return Padding(
      padding: EdgeInsets.only(left: 12, right: 12, bottom: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 3,
            // As tall as the text it labels; a fixed height either floats
            // above a one-line quote or runs past a long one.
            constraints: const BoxConstraints(minHeight: 18),
            margin: const EdgeInsets.only(top: 2, right: 8),
            color: tg.accent,
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (author.isNotEmpty)
                  Text(
                    author,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: TgDimens.timeFontSize,
                      fontWeight: FontWeight.w600,
                      color: tg.accent,
                    ),
                  ),
                Text(
                  body,
                  // Two lines: enough to recognise the message being answered,
                  // not so much that the quote competes with the reply.
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: TgDimens.timeFontSize,
                    color: tg.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One emoji's chip: the glyph, how many people, and whether we are among
/// them.
///
/// The count is on the chip rather than hidden behind a long press because the
/// question a reader asks first is "is this what I thought", not "who".
class ReactionChip extends StatelessWidget {
  const ReactionChip({super.key, required this.reaction, this.onTap});

  final ReactionGroup reaction;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      // Tinted rather than filled: our own reaction has to be readable at a
      // glance across a list, without the chip competing with the message.
      color: reaction.mine
          ? theme.colorScheme.primaryContainer
          : theme.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(reaction.emoji, style: const TextStyle(fontSize: 14)),
              if (reaction.count > 1) ...[
                const SizedBox(width: 4),
                Text(
                  '${reaction.count}',
                  style: TextStyle(
                    fontSize: TgDimens.timeFontSize,
                    fontWeight: FontWeight.w600,
                    color: reaction.mine
                        ? theme.colorScheme.onPrimaryContainer
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Timestamp, receipt ticks and the track this message used.
///
/// The track sits in the meta row rather than its own line: it is metadata
/// about the message, and the two-letter code is only readable at the size
/// the timestamp is already drawn at.
class _MetaRow extends StatelessWidget {
  const _MetaRow({
    required this.time,
    required this.delivered,
    required this.displayed,
    required this.failed,
    required this.mine,
    required this.track,
  });

  final DateTime time;
  final bool delivered;
  final bool displayed;
  final bool failed;
  final bool mine;
  final Track track;

  String get _timeText {
    final h = time.hour.toString().padLeft(2, '0');
    final m = time.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  @override
  Widget build(BuildContext context) {
    final tg = context.tg;
    // Sent = one tick; delivered (0184) or read (0333) = two.
    // Accent colour only for read, so the second tick visibly changes when
    // the peer opens the chat (Telegram-style; Conversations uses the same
    // icon for both received and displayed).
    final ticks = !mine
        ? null
        : failed
        ? Icons.error_outline
        : (delivered || displayed)
        ? Icons.done_all
        : Icons.done;
    final tickColor = failed
        ? tg.danger
        : displayed
        ? tg.accent
        : tg.textSecondary;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          _timeText,
          style: TextStyle(
            fontSize: TgDimens.timeFontSize,
            color: failed ? tg.danger : tg.textSecondary,
          ),
        ),
        if (ticks != null) ...[
          const SizedBox(width: 3),
          Icon(ticks, size: 14, color: tickColor),
        ],
        // Before the ticks on outgoing messages, after on incoming ones, so
        // the track lines up on the outer edge of the bubble either way.
        const SizedBox(width: 5),
        Icon(
          track.icon,
          size: 12,
          color: track == Track.none ? tg.danger : tg.textSecondary,
        ),
        const SizedBox(width: 1),
        Text(
          track.label,
          style: TextStyle(
            fontSize: TgDimens.timeFontSize - 1,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.3,
            color: track == Track.none ? tg.danger : tg.textSecondary,
          ),
        ),
      ],
    );
  }
}

/// Centred pill used to separate days in the message list.
class DateSeparator extends StatelessWidget {
  const DateSeparator({super.key, required this.date});

  final DateTime date;

  String _label(AppLocalizations l10n) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final that = DateTime(date.year, date.month, date.day);
    final delta = today.difference(that).inDays;
    if (delta == 0) return l10n.today;
    if (delta == 1) return l10n.yesterday;
    return '${date.day}/${date.month}/${date.year}';
  }

  @override
  Widget build(BuildContext context) {
    final tg = context.tg;
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: tg.dateSeparator,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            _label(l10n),
            style: TextStyle(
              fontSize: TgDimens.timeFontSize,
              color: tg.dateSeparatorText,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}
