// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copinc Untracker.java + Untracker findUrls, with native Dart rules.
// Tracking detection always compares against [normalizeUrlString]'d URLs so
// mere `//` → `/` path regularization is not treated as tracking removal.

import 'package:resonchat/net/fetch.dart';
import 'package:resonchat/untracker/rule.dart';
import 'package:resonchat/untracker/rules.dart';
import 'package:resonchat/untracker/url.dart';

final _ignoredScheme = RegExp(r'^(rtsp|ftp)://', caseSensitive: false);
final _hasScheme = RegExp(r'^https?://', caseSensitive: false);

/// Loose Autolink-style finder (Untracker / LinkifyCompat).
final _urlPattern = RegExp(
  r'(?:https?://|www\.)[^\s<>"\]<>]+',
  caseSensitive: false,
);

class _UrlHit {
  _UrlHit({
    required this.start,
    required this.end,
    required this.hasScheme,
    required this.original,
    required this.normalized,
  });

  final int start;
  final int end;
  final bool hasScheme;

  /// Exact substring from the message body.
  final String original;

  /// Scheme-ensured + path-normalized form used for inspect/untrack.
  final String normalized;
}

/// Result of cleaning a message body.
class UntrackResult {
  const UntrackResult({required this.text, required this.changed});

  /// Body after cleaning (original spans kept when only path-normalized).
  final String text;

  /// True when at least one URL was rewritten beyond path normalization.
  final bool changed;
}

/// Find URLs, inspect for tracking, and optionally remove it.
class Untracker {
  Untracker(this.text, {List<UntrackRule>? rules, UntrackFetch? fetch})
    : _rules = rules ?? builtinUntrackRules(),
      _fetch = fetch ?? untrackFetch {
    _hits = _findUrls(text);
  }

  final String text;
  final List<UntrackRule> _rules;
  final UntrackFetch _fetch;
  late final List<_UrlHit> _hits;

  /// True when any URL (after path normalize) matches a cleaning rule.
  bool inspect() {
    if (_hits.isEmpty || _rules.isEmpty) return false;
    for (final hit in _hits) {
      final url = TrackUrl(hit.normalized);
      for (final rule in _rules) {
        if (rule.inspect(url)) return true;
      }
    }
    return false;
  }

  /// Apply all rules. Throws on network/fetch failure (short-link expansion).
  ///
  /// Only replaces a URL span when the cleaned URL differs from the
  /// **normalized** input — path regularization alone keeps the original text.
  Future<UntrackResult> untrack() async {
    if (_hits.isEmpty || _rules.isEmpty) {
      return UntrackResult(text: text, changed: false);
    }

    // Right-to-left like Copinc so indices stay valid while replacing.
    final hits = _hits.toList()..sort((a, b) => b.start.compareTo(a.start));
    var out = text;
    var changed = false;

    for (final hit in hits) {
      var current = hit.normalized;
      for (final rule in _rules) {
        final u = TrackUrl(current);
        if (!rule.inspect(u)) continue;
        current = normalizeUrlString(await rule.untrack(u, _fetch));
      }

      if (current == hit.normalized) {
        // No tracking removed — keep the user's original characters
        // (including intentional `//`).
        continue;
      }

      changed = true;
      var replacement = current;
      if (!hit.hasScheme && replacement.startsWith('http://')) {
        replacement = replacement.substring('http://'.length);
      }
      out = out.replaceRange(hit.start, hit.end, replacement);
    }

    return UntrackResult(text: out, changed: changed);
  }
}

List<_UrlHit> _findUrls(String text) {
  final out = <_UrlHit>[];
  for (final m in _urlPattern.allMatches(text)) {
    var match = m.group(0)!;
    // Trim trailing punctuation commonly glued to URLs.
    match = match.replaceFirst(RegExp(r'[),.\]>]+$'), '');
    final start = m.start;
    final end = start + match.length;
    if (_ignoredScheme.hasMatch(match)) continue;
    final hasScheme = _hasScheme.hasMatch(match);
    final withScheme = hasScheme ? match : 'http://$match';
    final uri = Uri.tryParse(withScheme);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) continue;
    if (uri.scheme != 'http' && uri.scheme != 'https') continue;
    out.add(
      _UrlHit(
        start: start,
        end: end,
        hasScheme: hasScheme,
        original: match,
        normalized: normalizeUrlString(withScheme),
      ),
    );
  }
  return out;
}
