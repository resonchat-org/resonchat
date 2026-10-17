// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Pure helpers for the contacts search field (no Flutter / Riverpod).

/// Non-empty local and domain parts around `@` (bare JID, no spaces).
String? completeJidCandidate(String raw) {
  final t = raw.trim();
  if (t.isEmpty || t.contains(RegExp(r'\s'))) return null;
  final at = t.indexOf('@');
  if (at <= 0 || at >= t.length - 1) return null;
  if (t.contains('/')) return null;
  return t;
}

/// Loose match on display name and JID (substring + compact + subsequence).
bool matchesNameOrJid({
  required String name,
  required String jid,
  required String needle,
}) {
  final n = needle.trim().toLowerCase();
  if (n.isEmpty) return true;
  final local = jid.toLowerCase().split('@').first;
  return looseHaystack(name.toLowerCase(), n) ||
      looseHaystack(jid.toLowerCase(), n) ||
      looseHaystack(local, n);
}

bool looseHaystack(String haystack, String needle) {
  if (haystack.contains(needle)) return true;
  final compactN = needle.replaceAll(RegExp(r'[\s._-]'), '');
  final compactH = haystack.replaceAll(RegExp(r'[\s._-]'), '');
  if (compactN.isNotEmpty && compactH.contains(compactN)) return true;
  var i = 0;
  for (final c in compactH.codeUnits) {
    if (i < compactN.length && c == compactN.codeUnitAt(i)) i++;
  }
  return compactN.isNotEmpty && i == compactN.length;
}

/// First [limit] items unless [expanded].
List<T> visibleSlice<T>(List<T> all, {required bool expanded, int limit = 3}) {
  if (expanded || all.length <= limit) return all;
  return all.sublist(0, limit);
}
