// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Insert a MUC nick into the composer the way Conversations does
// (`ConversationFragment.highlightInConference`): leading `nick: ` at the
// start of a line, `, nick` when extending an existing mention list, and a
// plain nick with surrounding spaces otherwise.

/// Composer text and caret after a conference-mention insert.
class ConferenceMentionEdit {
  const ConferenceMentionEdit({required this.text, required this.selection});

  /// Full composer contents after the edit.
  final String text;

  /// Caret offset (collapsed selection) after the edit.
  final int selection;
}

/// Inserts [nick] into [text] at [selectionStart], following Conversations.
///
/// [areValidNicks] is Conversations' `NickValidityChecker`: when the caret sits
/// after `: ` and the tokens before it (split on `, `) are all known room
/// nicks, the new nick is spliced in as `, nick` before that `: `.
ConferenceMentionEdit insertConferenceMention({
  required String text,
  required int selectionStart,
  required String nick,
  required bool Function(List<String> nicks) areValidNicks,
}) {
  final trimmedNick = nick.trim();
  if (trimmedNick.isEmpty) {
    final pos = _clampSelection(text, selectionStart);
    return ConferenceMentionEdit(text: text, selection: pos);
  }

  final pos = _clampSelection(text, selectionStart);
  final oldTrimmed = text.trim();

  if (oldTrimmed.isEmpty || pos == 0) {
    final insert = '$trimmedNick: ';
    return ConferenceMentionEdit(
      text: '$insert$text',
      selection: insert.length,
    );
  }

  final before = text[pos - 1];
  final after = pos < text.length ? text[pos] : '';

  if (before == '\n') {
    final insert = '$trimmedNick: ';
    return ConferenceMentionEdit(
      text: text.replaceRange(pos, pos, insert),
      selection: pos + insert.length,
    );
  }

  if (pos > 2 && text.substring(pos - 2, pos) == ': ') {
    final prefix = text.substring(0, pos - 2);
    final previous = prefix.split(', ');
    if (areValidNicks(previous)) {
      final insert = ', $trimmedNick';
      // Conversations inserts before `: ` while the caret sits *after* that
      // marker; Android then shifts the caret by insert.length so it stays
      // after `: ` — required for a third avatar tap to keep comma-merging.
      return ConferenceMentionEdit(
        text: text.replaceRange(pos - 2, pos - 2, insert),
        selection: pos + insert.length,
      );
    }
  }

  final leading = _isWhitespace(before) ? '' : ' ';
  final trailing = after.isNotEmpty && _isWhitespace(after) ? '' : ' ';
  final insert = '$leading$trimmedNick$trailing';
  var selection = pos + insert.length;
  // Conversations advances one past an existing trailing whitespace so the
  // caret sits after the gap that already separated the next word.
  if (after.isNotEmpty && _isWhitespace(after)) {
    selection += 1;
  }
  return ConferenceMentionEdit(
    text: text.replaceRange(pos, pos, insert),
    selection: selection.clamp(0, text.length + insert.length),
  );
}

int _clampSelection(String text, int selectionStart) {
  if (selectionStart < 0) return text.length;
  if (selectionStart > text.length) return text.length;
  return selectionStart;
}

bool _isWhitespace(String ch) {
  if (ch.isEmpty) return false;
  return RegExp(r'^\s$', unicode: true).hasMatch(ch);
}

/// Session helper for avatar-tap mentions (Conversations NickValidityChecker
/// stand-in when the MUC roster is still empty).
class ConferenceMentionSession {
  final _remembered = <String>{};

  /// Inserts [nick] into the composer, remembering it for later comma-merges.
  ConferenceMentionEdit apply({
    required String text,
    required int selectionStart,
    required String nick,
    Iterable<String> occupantNicks = const [],
  }) {
    final trimmed = nick.trim();
    final known = <String>{
      ...occupantNicks,
      ..._remembered,
      if (trimmed.isNotEmpty) trimmed,
    };
    final edit = insertConferenceMention(
      text: text,
      selectionStart: selectionStart,
      nick: trimmed,
      areValidNicks: (nicks) =>
          nicks.isNotEmpty &&
          nicks.every((n) => n.isNotEmpty && known.contains(n)),
    );
    if (trimmed.isNotEmpty) _remembered.add(trimmed);
    return edit;
  }
}
