// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Gajim `plain_widget.print_text_with_styling` emoji-only enlarge.

/// Rough “emoji presentation” ranges + ZWJ / VS16 / keycaps / flags.
final _emojiChar = RegExp(
  r'(?:'
  r'[\u{1F1E6}-\u{1F1FF}]{2}' // flags
  r'|[\u{1F300}-\u{1FAFF}]' // misc pictographs / supplemental
  r'|[\u{2600}-\u{27BF}]' // misc symbols / dingbats
  r'|[\u{2300}-\u{23FF}]' // technical
  r'|[\u{2B50}\u{2B55}\u{3030}\u{303D}\u{3297}\u{3299}]'
  r'|[0-9#*]\u{FE0F}?\u{20E3}' // keycaps
  r')'
  r'(?:\u{FE0F}|\u{200D}(?:'
  r'[\u{1F300}-\u{1FAFF}]|[\u{2600}-\u{27BF}]|[\u{1F1E6}-\u{1F1FF}]'
  r')\u{FE0F}?)?',
  unicode: true,
);

/// True when [text] (trimmed) is only emoji / ZWJ sequences (Gajim `purely_emoji`).
bool isEmojiOnlyMessage(String text) {
  final stripped = text.trim();
  if (stripped.isEmpty) return false;
  var i = 0;
  var count = 0;
  while (i < stripped.length) {
    if (stripped.codeUnitAt(i) <= 0x20) {
      // Allow spaces between emoji clusters (Gajim counts after strip of markup).
      i++;
      continue;
    }
    final m = _emojiChar.matchAsPrefix(stripped, i);
    if (m == null) return false;
    count++;
    i = m.end;
  }
  return count > 0;
}

/// Number of emoji clusters in an emoji-only [text], or 0 if mixed.
int emojiOnlyCount(String text) {
  if (!isEmojiOnlyMessage(text)) return 0;
  final stripped = text.trim();
  var i = 0;
  var count = 0;
  while (i < stripped.length) {
    if (stripped.codeUnitAt(i) <= 0x20) {
      i++;
      continue;
    }
    final m = _emojiChar.matchAsPrefix(stripped, i);
    if (m == null) break;
    count++;
    i = m.end;
  }
  return count;
}

/// Font size multiplier for emoji-only bodies (Gajim CSS ~36pt / ~24pt vs ~14).
double emojiOnlyScale(String text) {
  final n = emojiOnlyCount(text);
  if (n <= 0) return 1;
  if (n == 1) return 2.4; // ~36/15
  return 1.6; // ~24/15
}
