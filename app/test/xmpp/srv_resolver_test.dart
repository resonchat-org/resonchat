// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The SRV lookup is the one network call a login can make that is not part of
// the XMPP session itself, and it is made only when a direct connection has
// already failed. Two things therefore have to hold: it asks the right
// question, and it never turns its own failure into a login failure.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:resonchat/xmpp/srv_resolver.dart';

/// A `dns-json` answer body.
String _answer(List<Map<String, Object?>> records, {int status = 0}) =>
    jsonEncode({'Status': status, 'Answer': records});

Map<String, Object?> _srv(String data) => {'type': 33, 'data': data};

DohSrvResolver _resolverReturning(String body, {int status = 200}) =>
    DohSrvResolver(
      endpoint: Uri.parse('https://resolver.invalid/dns-query'),
      clientFactory: () => MockClient(
        (request) async => http.Response(body, status),
      ),
    );

void main() {
  group('DohSrvResolver.query', () {
    test('asks the resolver for SRV records by name', () async {
      Uri? asked;
      final resolver = DohSrvResolver(
        endpoint: Uri.parse('https://resolver.invalid/dns-query'),
        clientFactory: () => MockClient((request) async {
          asked = request.url;
          return http.Response(_answer(const []), 200);
        }),
      );

      await resolver.query('_xmpp-client._tcp.example.org');

      expect(asked, isNotNull);
      expect(asked!.host, 'resolver.invalid');
      expect(asked!.queryParameters['name'], '_xmpp-client._tcp.example.org');
      expect(asked!.queryParameters['type'], 'SRV');
    });

    test('parses priority, weight, port and target', () async {
      final resolver = _resolverReturning(
        _answer([
          _srv('5 0 5222 xmpp.example.org.'),
          _srv('10 3 5269 backup.example.org.'),
        ]),
      );

      final records = await resolver.query('_xmpp-client._tcp.example.org');

      expect(records, hasLength(2));
      expect(records[0].priority, 5);
      expect(records[0].weight, 0);
      expect(records[0].port, 5222);
      // The root dot is DNS notation, not part of the host we dial.
      expect(records[0].target, 'xmpp.example.org');
      expect(records[1].target, 'backup.example.org');
    });

    test('ignores answers that are not SRV records', () async {
      final resolver = _resolverReturning(
        _answer([
          {'type': 5, 'data': 'xmpp.example.org.'},
          _srv('0 0 5223 direct.example.org.'),
          {'type': 1, 'data': '93.184.216.34'},
        ]),
      );

      final records = await resolver.query('_xmpps-client._tcp.example.org');

      expect(records, hasLength(1));
      expect(records.single.port, 5223);
      expect(records.single.target, 'direct.example.org');
    });

    test('skips a malformed record but keeps the rest', () async {
      final resolver = _resolverReturning(
        _answer([
          _srv('not a record'),
          _srv('5 0 5222 good.example.org.'),
          _srv('5 0 99999 out-of-range-port.example.org.'),
        ]),
      );

      final records = await resolver.query('_xmpp-client._tcp.example.org');

      expect(records, hasLength(1));
      expect(records.single.target, 'good.example.org');
    });

    test('a DNS error status means "no records", not an exception', () async {
      // NXDOMAIN. The caller falls back to the direct address.
      final resolver = _resolverReturning(
        _answer(const [], status: 3),
      );

      expect(await resolver.query('_xmpp-client._tcp.example.org'), isEmpty);
    });

    test('a non-200 response means "no records"', () async {
      final resolver = _resolverReturning('', status: 503);

      expect(await resolver.query('_xmpp-client._tcp.example.org'), isEmpty);
    });

    test('a body that is not JSON means "no records"', () async {
      final resolver = _resolverReturning('<html>nope</html>');

      expect(await resolver.query('_xmpp-client._tcp.example.org'), isEmpty);
    });

    test('a transport failure means "no records"', () async {
      final resolver = DohSrvResolver(
        endpoint: Uri.parse('https://resolver.invalid/dns-query'),
        clientFactory: () => MockClient(
          (request) async => throw const SocketException('unreachable'),
        ),
      );

      expect(
        await resolver.query('_xmpp-client._tcp.example.org'),
        isEmpty,
      );
    });

    test('a hanging resolver gives up rather than stalling the login', () async {
      final resolver = DohSrvResolver(
        endpoint: Uri.parse('https://resolver.invalid/dns-query'),
        timeout: const Duration(milliseconds: 10),
        clientFactory: () => MockClient((request) async {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          return http.Response(_answer(const []), 200);
        }),
      );

      expect(await resolver.query('_xmpp-client._tcp.example.org'), isEmpty);
    });

    test('the result is modifiable, because the connect path sorts it', () async {
      // `TCPSocketWrapper._rfc6120Connect` calls `results.sort(...)`. Returning
      // an unmodifiable list throws out of the connect path, so every result
      // has to be growable — including the empty ones.
      final withRecords = await _resolverReturning(
        _answer([_srv('5 0 5222 xmpp.example.org.')]),
      ).query('_xmpp-client._tcp.example.org');
      expect(() => withRecords.sort((a, b) => 0), returnsNormally);

      final empty = await _resolverReturning(
        _answer(const []),
      ).query('_xmpp-client._tcp.example.org');
      expect(() => empty.sort((a, b) => 0), returnsNormally);
    });
  });
}
