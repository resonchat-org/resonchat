// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// URL helpers translated from Untracker Builtins / Copinc Url.java
// (no QuickJS — native Dart only).

/// Hierarchical URL with Untracker-style match / query helpers.
class TrackUrl {
  TrackUrl(String url) : uri = Uri.parse(url);

  TrackUrl.fromUri(this.uri);

  final Uri uri;

  @override
  String toString() => uri.toString();

  /// Full-string match like Java `Pattern.matches` / Untracker `Regex.matches`.
  bool matches(
    String? hostPattern, [
    String? encodedPathPattern,
    String? encodedQueryPattern,
    String? encodedFragmentPattern,
  ]) {
    if (hostPattern != null) {
      final host = uri.host;
      if (host.isEmpty || !_fullMatch(hostPattern, host)) return false;
    }
    if (encodedPathPattern != null) {
      final path = uri.path.isEmpty ? '/' : uri.path;
      if (!_fullMatch(encodedPathPattern, path)) return false;
    }
    if (encodedQueryPattern != null) {
      final q = uri.query;
      if (q.isNotEmpty && !_fullMatch(encodedQueryPattern, q)) return false;
    }
    if (encodedFragmentPattern != null) {
      final f = uri.fragment;
      if (f.isNotEmpty && !_fullMatch(encodedFragmentPattern, f)) {
        return false;
      }
    }
    return true;
  }

  static bool _fullMatch(String pattern, String input) =>
      RegExp('^(?:$pattern)\$', caseSensitive: false).hasMatch(input);

  String get host => uri.host;

  String get encodedPath => uri.path.isEmpty ? '/' : uri.path;

  String? get encodedQuery => uri.hasQuery ? uri.query : null;

  String? queryParameter(String key) => uri.queryParameters[key];

  String? get encodedFragment => uri.hasFragment ? uri.fragment : null;

  TrackUrl setHost(String host) {
    return TrackUrl.fromUri(uri.replace(host: host));
  }

  TrackUrl setEncodedPath(String encodedPath) {
    return TrackUrl.fromUri(uri.replace(path: encodedPath));
  }

  TrackUrl setEncodedQuery(String? encodedQuery) {
    if (encodedQuery == null || encodedQuery.isEmpty) {
      return TrackUrl.fromUri(
        Uri(
          scheme: uri.scheme,
          userInfo: uri.userInfo.isEmpty ? null : uri.userInfo,
          host: uri.host,
          port: uri.hasPort ? uri.port : null,
          path: uri.path,
          fragment: uri.hasFragment ? uri.fragment : null,
        ),
      );
    }
    return TrackUrl.fromUri(uri.replace(query: encodedQuery));
  }

  TrackUrl setEncodedFragment(String? encodedFragment) {
    return TrackUrl.fromUri(uri.replace(fragment: encodedFragment));
  }

  bool containQueryParameters(String keyPattern, [String? valuePattern]) =>
      _containQueryParameters(keyPattern, valuePattern, invertMatch: false);

  bool containQueryParametersOutOf(String keyPattern, [String? valuePattern]) =>
      _containQueryParameters(keyPattern, valuePattern, invertMatch: true);

  bool _containQueryParameters(
    String? keyPattern,
    String? valuePattern, {
    required bool invertMatch,
  }) {
    final keyRe = keyPattern == null
        ? null
        : RegExp('^(?:$keyPattern)\$', caseSensitive: false);
    final valueRe = valuePattern == null
        ? null
        : RegExp('^(?:$valuePattern)\$', caseSensitive: false);
    for (final e in _queryPairs) {
      final matches =
          (keyRe == null || keyRe.hasMatch(e.key)) &&
          (valueRe == null || valueRe.hasMatch(e.value));
      if (matches == !invertMatch) return true;
    }
    return false;
  }

  TrackUrl removeQueryParameters(String keyPattern, [String? valuePattern]) =>
      _filterQuery(keyPattern, valuePattern, invertMatch: false);

  TrackUrl retainQueryParameters(String keyPattern, [String? valuePattern]) =>
      _filterQuery(keyPattern, valuePattern, invertMatch: true);

  TrackUrl _filterQuery(
    String? keyPattern,
    String? valuePattern, {
    required bool invertMatch,
  }) {
    final keyRe = keyPattern == null
        ? null
        : RegExp('^(?:$keyPattern)\$', caseSensitive: false);
    final valueRe = valuePattern == null
        ? null
        : RegExp('^(?:$valuePattern)\$', caseSensitive: false);
    final kept = <String, String>{};
    for (final e in _queryPairs) {
      final matches =
          (keyRe == null || keyRe.hasMatch(e.key)) &&
          (valueRe == null || valueRe.hasMatch(e.value));
      if (matches == !invertMatch) continue;
      kept[e.key] = e.value;
    }
    if (kept.isEmpty) return setEncodedQuery(null);
    return TrackUrl.fromUri(uri.replace(queryParameters: kept));
  }

  List<({String key, String value})> get _queryPairs {
    if (!uri.hasQuery) return const [];
    final out = <({String key, String value})>[];
    for (final part in uri.query.split('&')) {
      if (part.isEmpty) continue;
      final eq = part.indexOf('=');
      final rawKey = eq < 0 ? part : part.substring(0, eq);
      final rawVal = eq < 0 ? '' : part.substring(eq + 1);
      out.add((
        key: Uri.decodeQueryComponent(rawKey),
        value: Uri.decodeQueryComponent(rawVal),
      ));
    }
    return out;
  }
}

/// Collapse empty path segments (`//` → `/`) and `.` / `..` like Java
/// [URI.normalize], so tracking detection is not confused with mere
/// path regularization.
String normalizeUrlString(String url) {
  final uri = Uri.parse(url);
  if (!uri.hasScheme || uri.host.isEmpty) return url;
  final segments = <String>[];
  for (final seg in uri.pathSegments) {
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') {
      if (segments.isNotEmpty) segments.removeLast();
      continue;
    }
    segments.add(seg);
  }
  final path = uri.path.endsWith('/') && segments.isNotEmpty
      ? '/${segments.join('/')}/'
      : (segments.isEmpty
            ? (uri.path.startsWith('/') ? '/' : '')
            : '/${segments.join('/')}');
  return Uri(
    scheme: uri.scheme,
    userInfo: uri.userInfo.isEmpty ? null : uri.userInfo,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    path: path.isEmpty ? '/' : path,
    query: uri.hasQuery ? uri.query : null,
    fragment: uri.hasFragment ? uri.fragment : null,
  ).toString();
}
