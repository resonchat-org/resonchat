// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:io';

import 'package:resonchat/net/app_network.dart';

/// HTTP GET via [appNetwork] sockets (SOCKS when enabled).
Future<({int status, Map<String, String> headers, String body, String url})>
untrackFetch(String url, {required bool followRedirects}) async {
  final uri = Uri.parse(url);
  final client = HttpClient();
  client.connectionFactory = (u, proxyHost, proxyPort) async {
    final port = u.hasPort ? u.port : (u.scheme == 'https' ? 443 : 80);
    Socket? raw;
    final future = () async {
      raw = await appNetwork.openTcp(u.host, port);
      if (u.scheme == 'https') {
        return appNetwork.secureSocket(raw!, host: u.host);
      }
      return raw!;
    }();
    return ConnectionTask.fromSocket(future, () {
      raw?.destroy();
    });
  };
  client.connectionTimeout = const Duration(seconds: 20);
  try {
    final req = await client.getUrl(uri);
    req.followRedirects = followRedirects;
    req.maxRedirects = followRedirects ? 5 : 0;
    final resp = await req.close().timeout(const Duration(seconds: 30));
    final body = await resp.transform(utf8.decoder).join();
    final headers = <String, String>{};
    resp.headers.forEach((name, values) {
      if (values.isNotEmpty) headers[name] = values.first;
    });
    return (
      status: resp.statusCode,
      headers: headers,
      body: body,
      url: resp.redirects.isNotEmpty
          ? resp.redirects.last.location.toString()
          : url,
    );
  } finally {
    client.close(force: true);
  }
}
