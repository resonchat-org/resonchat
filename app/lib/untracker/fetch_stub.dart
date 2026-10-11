// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

/// Web cannot open arbitrary TCP for short-link expansion.
Future<({int status, Map<String, String> headers, String body, String url})>
untrackFetch(String url, {required bool followRedirects}) async {
  throw UnsupportedError('Untracker fetch is not available on web');
}
