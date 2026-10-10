// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Whether a chat message body is worth offering "Translate" for.

/// True when [body] has letters or digits (not empty / whitespace / emoji-only).
bool isTranslatableText(String body) {
  final t = body.trim();
  if (t.isEmpty) return false;
  for (final rune in t.runes) {
    final ch = String.fromCharCode(rune);
    // Letters (any script) or ASCII digits — skip pure emoji / punctuation.
    if (RegExp(r'\p{L}', unicode: true).hasMatch(ch) ||
        RegExp(r'\p{N}', unicode: true).hasMatch(ch)) {
      return true;
    }
  }
  return false;
}

/// Whether the message-action menu should offer Translate.
///
/// Hides for empty / emoji-only bodies, undecrypted or retracted rows, and
/// media/file messages (`mediaUrl` / local attachment).
bool canOfferTranslate({
  required String body,
  required bool decrypted,
  required bool retracted,
  required bool hasMedia,
}) {
  if (retracted || !decrypted || hasMedia) return false;
  return isTranslatableText(body);
}
