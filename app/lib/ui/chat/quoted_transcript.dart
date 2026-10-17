// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Quoted transcript for multi-select copy / forward: Gajim-style header
// (time + sender), `> `-prefixed bodies, consecutive same-sender messages
// within [mergeWindow] merged under one header when uninterrupted.
//
// Default window matches Conversations `Config.MESSAGE_MERGE_WINDOW` (90s).

/// Conversations `Config.MESSAGE_MERGE_WINDOW` — also used for transcript chrome.
const Duration kMessageMergeWindow = Duration(milliseconds: 90000);

/// One message ready for [formatQuotedTranscript].
class QuotedTranscriptItem {
  const QuotedTranscriptItem({
    required this.id,
    required this.body,
    required this.timestamp,
    required this.senderKey,
    required this.senderLabel,
  });

  /// Stable sort tie-breaker (e.g. stanza id).
  final String id;
  final String body;
  final DateTime timestamp;

  /// Identity for merge (same person).
  final String senderKey;

  /// Display name in the header.
  final String senderLabel;
}

/// Formats [items] as a quoted transcript (copy clipboard / forward body).
///
/// Sorted by timestamp (then [QuotedTranscriptItem.id]) so merges stay
/// chronological regardless of pick order.
String formatQuotedTranscript(
  Iterable<QuotedTranscriptItem> items, {
  Duration mergeWindow = kMessageMergeWindow,
  String Function(DateTime time)? formatTimestamp,
}) {
  final formatTime = formatTimestamp ?? _defaultTimestamp;
  final list = items.where((m) => m.body.trim().isNotEmpty).toList()
    ..sort((a, b) {
      final byTime = a.timestamp.compareTo(b.timestamp);
      if (byTime != 0) return byTime;
      return a.id.compareTo(b.id);
    });
  if (list.isEmpty) return '';

  final buf = StringBuffer();
  String? lastKey;
  DateTime? lastTime;

  for (final m in list) {
    final merge =
        lastKey != null &&
        m.senderKey == lastKey &&
        lastTime != null &&
        !m.timestamp.difference(lastTime).isNegative &&
        m.timestamp.difference(lastTime) <= mergeWindow;

    if (!merge) {
      if (buf.isNotEmpty) buf.writeln();
      buf.writeln('${formatTime(m.timestamp)} - ${m.senderLabel}:');
    }
    buf.write(quoteMessageBody(m.body));
    lastKey = m.senderKey;
    lastTime = m.timestamp;
  }

  return buf.toString().trimRight();
}

/// Gajim `quote_text`: each line of [body] prefixed with `> `.
String quoteMessageBody(String body) {
  final trimmed = body.trimRight();
  if (trimmed.isEmpty) return '';
  final lines = trimmed.split('\n');
  final buf = StringBuffer();
  for (final line in lines) {
    buf.writeln('> $line');
  }
  return buf.toString();
}

String _defaultTimestamp(DateTime time) {
  final local = time.toLocal();
  final y = local.year.toString().padLeft(4, '0');
  final mo = local.month.toString().padLeft(2, '0');
  final d = local.day.toString().padLeft(2, '0');
  final h = local.hour.toString().padLeft(2, '0');
  final mi = local.minute.toString().padLeft(2, '0');
  return '$y-$mo-$d $h:$mi';
}
