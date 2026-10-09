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
// than from a tally. When the count says unread but the marker finds nothing
// (same-second races; never-read chats), we fall back to the trailing unread
// incoming messages so the jump button still has a target.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../store/database.dart';
import '../theme.dart';

/// Stable key for the unread divider target (stanza id, or `__row_<id>`).
String unreadAnchorOf(Message m) =>
    m.stanzaId.isNotEmpty ? m.stanzaId : '__row_${m.id}';

/// True when [m] is the message the unread divider sits above.
bool matchesUnreadAnchor(Message m, String? anchor) {
  if (anchor == null) return false;
  return unreadAnchorOf(m) == anchor;
}

/// The id of the first message that was unread at [readAt], or null.
///
/// Null when everything here was already read, or when the read marker is
/// newer than every message we hold (read on another device).
///
/// When [unreadCount] is positive but the marker alone finds no boundary
/// (same-second insert vs `last_read_at`), falls back to the oldest of the
/// trailing unread *incoming* messages so the FAB / open-scroll still work.
String? firstUnreadId(
  List<Message> messages,
  DateTime? readAt, {
  int unreadCount = 0,
}) {
  if (readAt != null) {
    for (final m in messages) {
      if (m.timestamp.isAfter(readAt)) return unreadAnchorOf(m);
    }
  }
  if (unreadCount <= 0) return null;

  var remaining = unreadCount;
  Message? anchor;
  for (var i = messages.length - 1; i >= 0; i--) {
    if (!messages[i].incoming) continue;
    anchor = messages[i];
    remaining--;
    if (remaining <= 0) break;
  }
  return anchor == null ? null : unreadAnchorOf(anchor);
}

/// The row drawn between the read and unread parts of a conversation.
class UnreadDivider extends StatelessWidget {
  const UnreadDivider({super.key});

  @override
  Widget build(BuildContext context) {
    final tg = context.tg;
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Row(
        children: [
          Expanded(child: Divider(color: tg.accent.withValues(alpha: 0.7))),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text(
              l10n.unreadMessages,
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
