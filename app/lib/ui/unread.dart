// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The unread boundary in a conversation.
//
// Everything here is about one decision: where exactly does "you have read up
// to here" end? It is tempting to use the unread *count* — 3 unread means the
// divider goes above the third-from-last message — but the count is a number of
// arrivals, not a position, and it is wrong in ways that are invisible until
// the wrong line is drawn:
//
//   * A MAM import can add old messages at any time, so the count and the
//     position drift apart.
//   * A message that could not be decrypted still counts as unread, but it
//     renders as a system row rather than a bubble, so "three rows above the
//     divider" is not the third-from-last bubble.
//   * Reading on another device moves the boundary without changing any count
//     we can see.
//
// So the boundary is a timestamp — the read marker — and the divider goes above
// the first message after it. That is derived from what actually happened rather
// than from a tally.

import 'package:flutter/material.dart';

import '../store/database.dart';
import 'theme.dart';

/// The id of the first message that was unread at [readAt], or null.
///
/// Null in two distinct cases, and the difference matters for whether anything
/// should be drawn:
///
///   * everything here was already read — no boundary;
///   * the read marker is newer than every message we hold, which happens after
///     reading on another device. Drawing a divider here would put a line across
///     the top of a conversation with nothing above it.
String? firstUnreadId(List<Message> messages, DateTime? readAt) {
  if (readAt == null) return null;
  for (final m in messages) {
    if (m.timestamp.isAfter(readAt)) return m.stanzaId;
  }
  return null;
}

/// The row drawn between the read and unread parts of a conversation.
class UnreadDivider extends StatelessWidget {
  const UnreadDivider({super.key});

  @override
  Widget build(BuildContext context) {
    final tg = context.tg;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Row(
        children: [
          Expanded(child: Divider(color: tg.accent.withValues(alpha: 0.7))),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text(
              'Unread messages',
              style: TextStyle(
                fontSize: TgDimens.timeFontSize,
                fontWeight: FontWeight.w600,
                color: tg.accent,
              ),
            ),
          ),
          Expanded(child: Divider(color: tg.accent.withValues(alpha: 0.7))),
        ],
      ),
    );
  }
}
