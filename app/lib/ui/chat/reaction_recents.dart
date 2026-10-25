// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The menu's front reaction row is recency-ordered: six defaults until the user
// picks something from the full palette, then that emoji takes the first slot.
// Saved in the app-wide prefs DB so the row survives a restart.

import 'dart:convert';

import 'package:resonchat/persistence/prefs_database.dart';
import 'package:resonchat/ui/chat/emoji_data.dart';
import 'package:resonchat/xmpp/chat/reactions.dart';

const String _prefQuickReactionsKey = 'pref_quick_reactions';

/// How many emoji the menu's front row holds.
const int kQuickReactionSlots = 6;

/// U+2764 is a single code point, but text-presentation by default: Linux
/// draws it as a black glyph beside the coloured emoji. It is sendable by the
/// code-point rule, yet it is exactly the look the menu avoids, so prefs and
/// promotions are not allowed to put it on the row.
const String _textPresentationHeart = '❤';

bool _isMenuEmoji(String value) =>
    isSendableEmoji(value) && value != _textPresentationHeart;

/// The saved front row, or [kQuickReactions] when nothing usable is stored.
///
/// [prefs] is optional so a widget test can call this without opening the DB;
/// an unopened DB falls back to the defaults instead of failing the menu.
Future<List<String>> loadQuickReactions([PrefsDatabase? prefs]) async {
  try {
    final db = prefs ?? appPrefs;
    final raw = await db.getString(_prefQuickReactionsKey);
    if (raw == null || raw.isEmpty) return kQuickReactions;
    final decoded = jsonDecode(raw);
    if (decoded is! List) return kQuickReactions;
    return _normalise([
      for (final value in decoded)
        if (value is String) value,
    ]);
  } on Object {
    // Corrupt JSON, or prefs not opened yet (tests, very early start). The
    // defaults are always a valid row, so there is nothing else to do.
    return kQuickReactions;
  }
}

Future<void> saveQuickReactions(
  List<String> emoji, [
  PrefsDatabase? prefs,
]) async {
  try {
    final db = prefs ?? appPrefs;
    await db.setString(_prefQuickReactionsKey, jsonEncode(_normalise(emoji)));
  } on Object {
    // Persistence is a convenience. The row has already been updated in
    // memory, and a failed write must not take the reaction down with it.
  }
}

/// [emoji] moved to the front, keeping [kQuickReactionSlots] entries.
///
/// The emoji is validated before it is stored: the picker already filters to
/// sendable single code points, but the prefs row is also written from disk and
/// must never carry an unrenderable or multi-code-point value into a chip.
List<String> promoteQuickReaction(List<String> current, String emoji) {
  if (!_isMenuEmoji(emoji)) return List<String>.of(current);
  return _normalise([emoji, ...current.where((value) => value != emoji)]);
}

List<String> _normalise(List<String> values) {
  final seen = <String>{};
  final result = <String>[];
  for (final value in values) {
    if (!_isMenuEmoji(value) || !seen.add(value)) continue;
    result.add(value);
    if (result.length == kQuickReactionSlots) break;
  }
  for (final fallback in kQuickReactions) {
    if (result.length == kQuickReactionSlots) break;
    if (seen.add(fallback)) result.add(fallback);
  }
  return List<String>.unmodifiable(result);
}
