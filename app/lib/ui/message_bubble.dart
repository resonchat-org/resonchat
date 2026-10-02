// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Chat bubble translated from Telegram for Android's `ChatMessageCell`
// (GPL-2.0-or-later): rounded body with a corner tail, timestamp sitting
// on the same baseline as the text, and read receipts. Colours come from
// the theme; no Telegram assets are bundled.

import 'package:flutter/material.dart';

import '../omemo/track.dart';
import '../xmpp/reactions.dart';
import 'theme.dart';

enum BubbleSide { incoming, outgoing }

/// Paints a rounded rectangle whose one corner is squared off, forming the
/// tail that points at the sender.
class _BubblePainter extends CustomPainter {
  _BubblePainter({
    required this.color,
    required this.side,
    required this.radius,
    required this.tail,
  });

  final Color color;
  final BubbleSide side;
  final double radius;
  final double tail;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Radius.circular(radius);
    final path = Path();

    if (side == BubbleSide.outgoing) {
      // Tail at bottom-right.
      path
        ..moveTo(radius, 0)
        ..lineTo(size.width - radius, 0)
        ..arcToPoint(
          Offset(size.width, radius),
          radius: r,
        )
        ..lineTo(size.width, size.height - tail)
        ..lineTo(size.width - tail, size.height)
        ..lineTo(0, size.height)
        ..lineTo(0, radius)
        ..arcToPoint(Offset(radius, 0), radius: r)
        ..close();
    } else {
      // Tail at bottom-left.
      path
        ..moveTo(radius, 0)
        ..lineTo(size.width - radius, 0)
        ..arcToPoint(Offset(size.width, radius), radius: r)
        ..lineTo(size.width, size.height)
        ..lineTo(tail, size.height)
        ..lineTo(0, size.height - tail)
        ..lineTo(0, radius)
        ..arcToPoint(Offset(radius, 0), radius: r)
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
      old.tail != tail;
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
    this.failed = false,
    this.track = Track.none,
    this.reactions = const [],
    this.onReact,
    this.onLongPress,
    this.onTap,
  });

  final String text;
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

  /// Shown above the bubble in group chats, tinted per sender.
  final String? senderName;
  final Color? senderColor;

  /// True once a delivery receipt arrived (XEP-0184).
  final bool delivered;
  final bool failed;

  final VoidCallback? onLongPress;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tg = context.tg;
    final mine = side == BubbleSide.outgoing;
    final color = mine ? tg.ownBubble : tg.peerBubble;

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: 8,
        vertical: 1,
      ),
      child: Column(
        crossAxisAlignment:
            mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          if (senderName != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 2, left: 12, right: 12),
              child: Text(
                senderName!,
                style: TextStyle(
                  fontSize: 13,
                  color: senderColor ?? tg.accent,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          GestureDetector(
            onTap: onTap,
            onLongPress: onLongPress,
            child: CustomPaint(
              painter: _BubblePainter(
                color: color,
                side: side,
                radius: TgDimens.bubbleRadius,
                tail: TgDimens.bubbleTailSize,
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  TgDimens.bubblePaddingH + 4,
                  TgDimens.bubblePaddingV,
                  TgDimens.bubblePaddingH + 4,
                  TgDimens.bubblePaddingV,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Flexible(
                      child: Text(
                        text,
                        style: TextStyle(
                          fontSize: TgDimens.messageFontSize,
                          color: tg.textPrimary,
                          height: 1.3,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _MetaRow(
                      time: time,
                      delivered: delivered,
                      failed: failed,
                      mine: mine,
                      track: track,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (reactions.isNotEmpty)
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

/// One emoji's chip: the glyph, how many people, and whether we are among
/// them.
///
/// The count is on the chip rather than hidden behind a long press because the
/// question a reader asks first is "is this what I thought", not "who".
class ReactionChip extends StatelessWidget {
  const ReactionChip({
    super.key,
    required this.reaction,
    this.onTap,
  });

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
    required this.failed,
    required this.mine,
    required this.track,
  });

  final DateTime time;
  final bool delivered;
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
    final ticks = !mine
        ? null
        : failed
            ? Icons.error_outline
            : delivered
                ? Icons.done_all
                : Icons.done;
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
          Icon(
            ticks,
            size: 14,
            color: failed
                ? tg.danger
                : delivered
                    ? tg.accent
                    : tg.textSecondary,
          ),
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

  String get _label {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final that = DateTime(date.year, date.month, date.day);
    final delta = today.difference(that).inDays;
    if (delta == 0) return 'Today';
    if (delta == 1) return 'Yesterday';
    if (date.year == now.year) {
      return '${date.day}/${date.month}/${date.year}';
    }
    return '${date.day}/${date.month}/${date.year}';
  }

  @override
  Widget build(BuildContext context) {
    final tg = context.tg;
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
            _label,
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

/// Thin labelled line marking where the unread messages start.
class UnreadDivider extends StatelessWidget {
  const UnreadDivider({super.key});

  @override
  Widget build(BuildContext context) {
    final tg = context.tg;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
      child: Row(
        children: [
          Expanded(child: Divider(color: tg.accent, thickness: 1)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              'Unread messages',
              style: TextStyle(
                fontSize: TgDimens.timeFontSize,
                color: tg.accent,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(child: Divider(color: tg.accent, thickness: 1)),
        ],
      ),
    );
  }
}