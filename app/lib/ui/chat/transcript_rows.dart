// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Flat transcript rows shared by [ChatMessageList] and scroll jumps.
//
// Rows are ascending (oldest → newest). [ChatMessageList] uses a reverse
// ListView and maps `length - 1 - i`, so index 0 in the ListView is newest.
// Scroll helpers take these ascending indices and map them to offsets.

import 'package:resonchat/persistence/database.dart';
import 'package:resonchat/ui/chats/unread.dart';

/// One slot in the chat transcript [ListView].
enum TranscriptRowKind { loadingOlder, date, unread, message }

/// Lightweight row descriptor — no widgets, safe to rebuild every frame.
class TranscriptRow {
  const TranscriptRow._(this.kind, {this.message, this.date});

  const TranscriptRow.loadingOlder() : this._(TranscriptRowKind.loadingOlder);

  const TranscriptRow.date(DateTime day)
    : this._(TranscriptRowKind.date, date: day);

  const TranscriptRow.unread() : this._(TranscriptRowKind.unread);

  const TranscriptRow.message(Message m)
    : this._(TranscriptRowKind.message, message: m);

  final TranscriptRowKind kind;
  final Message? message;
  final DateTime? date;
}

/// Same shape as [ChatMessageList]: spinner, then per message date → unread → body.
List<TranscriptRow> buildTranscriptRows(
  List<Message> messages, {
  DateTime? readAt,
  int unreadCount = 0,
  bool loadingOlder = false,
}) {
  final rows = <TranscriptRow>[
    if (loadingOlder) const TranscriptRow.loadingOlder(),
  ];
  if (messages.isEmpty) return rows;

  final firstUnread = firstUnreadId(messages, readAt, unreadCount: unreadCount);
  var unreadMarked = firstUnread == null;
  DateTime? lastDay;

  for (final m in messages) {
    final day = DateTime(m.timestamp.year, m.timestamp.month, m.timestamp.day);
    if (lastDay == null || day != lastDay) {
      rows.add(TranscriptRow.date(m.timestamp));
      lastDay = day;
    }
    if (!unreadMarked && matchesUnreadAnchor(m, firstUnread)) {
      rows.add(const TranscriptRow.unread());
      unreadMarked = true;
    }
    rows.add(TranscriptRow.message(m));
  }
  return rows;
}

/// Index of the message row matching [anchor], or null.
int? focusRowIndexIn(List<TranscriptRow> rows, String anchor) {
  if (anchor.isEmpty) return null;
  for (var i = 0; i < rows.length; i++) {
    final m = rows[i].message;
    if (m != null && matchesFocusAnchor(m, anchor)) return i;
  }
  return null;
}

/// Index of the unread divider row, or null.
int? unreadDividerIndexIn(List<TranscriptRow> rows) {
  for (var i = 0; i < rows.length; i++) {
    if (rows[i].kind == TranscriptRowKind.unread) return i;
  }
  return null;
}
