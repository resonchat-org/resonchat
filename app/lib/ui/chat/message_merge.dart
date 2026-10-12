// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Conversations `MessageAdapter.merge`: whether two consecutive transcript
// rows share chrome (avatar / nick). Bubbles stay separate — only the header
// chrome is suppressed.

import '../../store/database.dart';
import 'chat_nicks.dart';
import 'quoted_transcript.dart';

/// Whether [later] may hide its avatar/nick because it continues [earlier].
///
/// Mirrors Conversations' checks that matter for our UI: same direction, same
/// MUC counterpart (or both outgoing), and within [kMessageMergeWindow].
bool messagesMergeForChrome(Message earlier, Message later) {
  if (earlier.incoming != later.incoming) return false;
  if (earlier.retracted || later.retracted) return false;

  if (earlier.incoming) {
    final a = occupantNick(earlier.sender) ?? earlier.sender;
    final b = occupantNick(later.sender) ?? later.sender;
    if (a != b) return false;
  }

  final delta = later.timestamp.difference(earlier.timestamp);
  if (delta.isNegative) return false;
  return delta <= kMessageMergeWindow;
}

bool _sameCalendarDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// Like [messagesMergeForChrome], but also refuses to merge across a day break
/// (date separators sit between those rows).
bool messagesMergeAcrossList(Message earlier, Message later) {
  if (!_sameCalendarDay(earlier.timestamp, later.timestamp)) return false;
  return messagesMergeForChrome(earlier, later);
}
