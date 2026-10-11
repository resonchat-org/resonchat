// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// DNS SRV for XMPP — RFC 6120 §3.2 (`_xmpp-client._tcp`) and XEP-0368
// (`_xmpps-client._tcp`) — resolved over DNS-over-HTTPS.
//
// Why DoH at all: Dart has no SRV API, `dart:io` resolves A/AAAA only, and the
// platform resolver is not reachable from Dart without a native plugin. Without
// this, `TCPSocketWrapper.srvQuery` keeps its default of returning no records,
// so the client only ever dials `<JID domain>:5222` and a domain whose C2S
// endpoint lives behind SRV cannot be reached at all.
//
// Why DoH is asked *last*, never first: see `SrvFallbackSocketWrapper`. The
// short version is that a query here tells a third-party resolver which XMPP
// domain the user is signing in to, and the great majority of servers answer on
// their own address without needing SRV — so the query is only worth making
// once a direct connection has already failed.
//
// Nothing in this file may throw: "no SRV records" is a normal answer and must
// degrade to the direct-connection fallback, not take the login down with it.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:moxxmpp_socket_tcp/moxxmpp_socket_tcp.dart';

/// The DNS RR type for SRV (RFC 2782); the `dns-json` API returns type numbers.
const int _srvRecordType = 33;

/// Looks up `_xmpp-client._tcp.<domain>` / `_xmpps-client._tcp.<domain>`.
///
/// Resolves over DNS-over-HTTPS using the JSON API (`application/dns-json`),
/// which needs no new dependency: `package:http` is already here. The wire
/// format would save nothing but a JSON decoder.
class DohSrvResolver {
  DohSrvResolver({
    Uri? endpoint,
    http.Client Function()? clientFactory,
    this.timeout = const Duration(seconds: 5),
  }) : endpoint = endpoint ?? cloudflareDnsQuery,
       _clientFactory = clientFactory ?? (() => http.Client());

  /// Cloudflare's public resolver. Chosen as the built-in default only because
  /// it is the one the fallback was reviewed with; [endpoint] is a parameter so
  /// a build can point somewhere else without touching this class.
  static final Uri cloudflareDnsQuery = Uri.parse(
    'https://cloudflare-dns.com/dns-query',
  );

  final Uri endpoint;

  /// Injected by the app so the lookup shares the SOCKS5 path (see
  /// `appNetwork.createHttpClient`); tests inject a `MockClient`.
  final http.Client Function() _clientFactory;

  final Duration timeout;

  final _log = Logger('DohSrvResolver');

  /// Created on first use and kept. A resolver is process-wide (see
  /// `createXmppSocket`), so closing per query would be wrong and creating per
  /// query would leak a connection pool for each one.
  http.Client? _client;

  http.Client get _http => _client ??= _clientFactory();

  /// SRV records for [name], or an empty list.
  ///
  /// Never throws. A resolution failure, a non-zero DNS status, a malformed
  /// body, a timeout and a plain "no such record" are all reported the same
  /// way, because the caller does the same thing for all of them: fall back to
  /// the server's own address.
  ///
  /// The returned list is always growable — the caller sorts it in place.
  Future<List<MoxSrvRecord>> query(String name) async {
    final uri = endpoint.replace(
      queryParameters: {'name': name, 'type': 'SRV'},
    );
    try {
      final response = await _http
          .get(uri, headers: const {'accept': 'application/dns-json'})
          .timeout(timeout);
      if (response.statusCode != 200) {
        _log.info('SRV $name: HTTP ${response.statusCode}');
        return <MoxSrvRecord>[];
      }
      final records = _parse(response.body);
      _log.info('SRV $name: ${records.length} record(s)');
      return records;
    } on Object catch (e) {
      // Deliberately broad: a TimeoutException, a TLS error, a socket error and
      // a FormatException are all "no records" as far as the caller is
      // concerned, and none of them is worth failing a login over.
      _log.info('SRV $name: lookup failed ($e)');
      return <MoxSrvRecord>[];
    }
  }

  /// Parses a `application/dns-json` body into SRV records.
  ///
  /// Shape (relevant parts):
  /// ```json
  /// {"Status":0,"Answer":[{"name":"_xmpp-client._tcp.ex","type":33,
  ///                        "data":"5 0 5222 xmpp.ex."}]}
  /// ```
  /// `data` is `priority weight port target`; the target keeps its trailing
  /// root dot, which is not part of the hostname we connect to.
  List<MoxSrvRecord> _parse(String body) {
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      return <MoxSrvRecord>[];
    }
    if (decoded is! Map) return <MoxSrvRecord>[];

    final status = decoded['Status'];
    if (status is int && status != 0) {
      // NXDOMAIN / SERVFAIL / REFUSED: an answer, and it is "nothing".
      return <MoxSrvRecord>[];
    }

    final answers = decoded['Answer'];
    if (answers is! List) return <MoxSrvRecord>[];

    final records = <MoxSrvRecord>[];
    for (final answer in answers) {
      if (answer is! Map) continue;
      if (answer['type'] != _srvRecordType) continue;

      final data = answer['data'];
      if (data is! String) continue;

      final parts = data.trim().split(RegExp(r'\s+'));
      if (parts.length < 4) continue;

      final priority = int.tryParse(parts[0]);
      final weight = int.tryParse(parts[1]);
      final port = int.tryParse(parts[2]);
      final target = parts[3];
      // A record we cannot make sense of is not a reason to discard the rest of
      // the answer — the next one may be usable.
      if (priority == null || weight == null || port == null) continue;
      if (port <= 0 || port > 65535) continue;
      if (target.isEmpty) continue;

      records.add(
        MoxSrvRecord(
          priority,
          weight,
          target.endsWith('.')
              ? target.substring(0, target.length - 1)
              : target,
          port,
        ),
      );
    }
    return records;
  }
}
