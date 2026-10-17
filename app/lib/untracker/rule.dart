// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copinc Rule.java — inspect without network; untrack may fetch.

import 'url.dart';

typedef UntrackFetch =
    Future<({int status, Map<String, String> headers, String body, String url})>
    Function(String url, {required bool followRedirects});

/// One built-in Untracker rule, as native Dart (no JS).
abstract class UntrackRule {
  const UntrackRule({required this.id, required this.description});

  final String id;
  final String description;

  /// Whether [url] (already [normalizeUrlString]'d) carries tracking this rule
  /// would remove. Must not treat path regularization as tracking.
  bool inspect(TrackUrl url);

  /// Cleaned URL for [url]. May call [fetch] for short-link expansion.
  Future<String> untrack(TrackUrl url, UntrackFetch fetch);
}

/// Rule that only rewrites locally (no HTTP).
abstract class LocalUntrackRule extends UntrackRule {
  const LocalUntrackRule({required super.id, required super.description});

  String clean(TrackUrl url);

  @override
  bool inspect(TrackUrl url) {
    // Compare normalized forms so path regularization alone is not tracking.
    final out = normalizeUrlString(clean(url));
    return out != normalizeUrlString(url.toString());
  }

  @override
  Future<String> untrack(TrackUrl url, UntrackFetch fetch) async => clean(url);
}
