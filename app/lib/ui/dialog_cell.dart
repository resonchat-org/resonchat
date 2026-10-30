// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The list row shared by Chats and Contacts.
//
// Telegram draws this as DialogCell: a fixed-height row, the chat-list
// avatar, a title, and an optional second line. ChatRow adds unread, time,
// and swipe on top of it. Contacts fill the same row with last seen and JID.

import 'package:flutter/material.dart';

import 'package:resonchat/ui/motion.dart';
import 'package:resonchat/ui/theme.dart';

class DialogCell extends StatefulWidget {
  const DialogCell({
    super.key,
    required this.leading,
    required this.title,
    this.titleWeight = FontWeight.w500,
    this.titleLeading = const [],
    this.titleTrailing,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.onLongPress,
    this.selected = false,
  });

  final Widget leading;
  final String title;
  final FontWeight titleWeight;
  final List<Widget> titleLeading;
  final Widget? titleTrailing;

  /// Second line. Omitted, the title sits in the middle of the row.
  final Widget? subtitle;

  /// Icon at the end of the row, outside the title line.
  final Widget? trailing;

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool selected;

  @override
  State<DialogCell> createState() => _DialogCellState();
}

class _DialogCellState extends State<DialogCell> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final tg = context.appColors;
    final subtitle = widget.subtitle;
    // A selected row in column mode has to remain findable while the pointer
    // is elsewhere; the hover wash is a lighter, transient version of it.
    // Fade from a transparent version of the accent, not transparent black:
    // interpolating towards `Colors.transparent` drags the fill through a
    // desaturated grey on a dark theme.
    final background = widget.selected
        ? tg.accent.withValues(alpha: 0.12)
        : _hovered
        ? tg.textPrimary.withValues(alpha: 0.035)
        : tg.accent.withValues(alpha: 0);

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: widget.onTap == null
          ? MouseCursor.defer
          : SystemMouseCursors.click,
      child: InkWell(
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        child: AnimatedContainer(
          duration: motionDuration(context, kMotionFast),
          curve: kMotionStandard,
          height: AppDimens.chatsRowHeight,
          color: background,
          padding: const EdgeInsets.symmetric(
            horizontal: AppDimens.chatsHorizontalPadding,
          ),
          child: Row(
            children: [
              widget.leading,
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        ...widget.titleLeading,
                        Expanded(
                          child: AnimatedDefaultTextStyle(
                            duration: motionDuration(context, kMotionFast),
                            curve: kMotionStandard,
                            style: TextStyle(
                              fontSize: AppDimens.chatTitleFontSize,
                              fontWeight: widget.titleWeight,
                              color: tg.textPrimary,
                            ),
                            child: Text(
                              widget.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                        ?widget.titleTrailing,
                      ],
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: AppDimens.chatsTitleGap),
                      subtitle,
                    ],
                  ],
                ),
              ),
              if (widget.trailing != null) ...[
                const SizedBox(width: 8),
                widget.trailing!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
