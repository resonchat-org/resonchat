// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The list row shared by Chats and Contacts.
//
// Telegram draws this as DialogCell: a fixed-height row, the chat-list
// avatar, a title, and an optional second line. ChatRow adds unread, time,
// and swipe on top of it. Contacts fill the same row with last seen and JID.

import 'package:flutter/material.dart';

import 'theme.dart';

class DialogCell extends StatelessWidget {
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
    this.stripe,
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

  /// Left account stripe. Null when the list is a single account.
  final Color? stripe;

  @override
  Widget build(BuildContext context) {
    final tg = context.tg;
    final subtitle = this.subtitle;
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        height: TgDimens.chatsRowHeight,
        decoration: BoxDecoration(
          color: selected ? tg.accent.withValues(alpha: 0.12) : null,
          border: stripe == null
              ? null
              : Border(left: BorderSide(color: stripe!, width: 3)),
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: TgDimens.chatsHorizontalPadding,
        ),
        child: Row(
          children: [
            leading,
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      ...titleLeading,
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: TgDimens.chatTitleFontSize,
                            fontWeight: titleWeight,
                            color: tg.textPrimary,
                          ),
                        ),
                      ),
                      ?titleTrailing,
                    ],
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: TgDimens.chatsTitleGap),
                    subtitle,
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[const SizedBox(width: 8), trailing!],
          ],
        ),
      ),
    );
  }
}
