// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Shared validation for typed XMPP addresses in forms and search.

/// Validates a user-typed JID and returns the trimmed candidate, or null.
///
/// Bare shape is always `local@domain.tld` (domain must have a label after a
/// `.`). Whitespace is rejected.
///
/// When [requireResource] is false (contacts, rooms, bans): a `/` is rejected
/// — only bare JIDs. When true (e.g. translation provider): a non-empty
/// resource after `/` is required (`local@domain.tld/resource`).
String? completeJidCandidate(String raw, {bool requireResource = false}) {
  final t = raw.trim();
  if (t.isEmpty || t.contains(RegExp(r'\s'))) return null;

  final slash = t.indexOf('/');
  if (requireResource) {
    if (slash <= 0 || slash >= t.length - 1) return null;
  } else if (slash >= 0) {
    return null;
  }

  final bare = slash < 0 ? t : t.substring(0, slash);
  final at = bare.indexOf('@');
  if (at <= 0 || at >= bare.length - 1) return null;
  if (bare.contains('@', at + 1)) return null;

  final domain = bare.substring(at + 1);
  final dot = domain.indexOf('.');
  if (dot <= 0 || dot >= domain.length - 1) return null;
  return t;
}

/// True when [raw] is empty (optional field) or a valid [completeJidCandidate].
bool jidInputOk(
  String raw, {
  bool requireResource = false,
  bool allowEmpty = false,
}) {
  final t = raw.trim();
  if (t.isEmpty) return allowEmpty;
  return completeJidCandidate(t, requireResource: requireResource) != null;
}
