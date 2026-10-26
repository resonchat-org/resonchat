// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The point of this wrapper is an ordering guarantee, and ordering is exactly
// what a code review of two async methods cannot verify. The SRV lookup tells a
// third-party resolver which XMPP domain is being signed in to, so it must not
// happen for a server that answers on its own address — and "must not" has to
// mean "does not", not "usually does not".

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moxxmpp/socket_tcp.dart';

import 'package:resonchat/xmpp/socket/xmpp_socket_io.dart';

/// Records every connect attempt and SRV query, in order, as `'tcp host:port'`
/// and `'srv name'`.
class _Recorder {
  final List<String> events = [];

  List<String> get queries =>
      events.where((e) => e.startsWith('srv ')).toList();
}

SrvFallbackSocketWrapper _wrapper(
  _Recorder recorder, {
  required Future<Socket> Function(String host, int port) connect,
}) => SrvFallbackSocketWrapper(
  srvLookup: (name) async {
    recorder.events.add('srv $name');
    // Growable, like the real resolver: the base class sorts it in place.
    return <MoxSrvRecord>[];
  },
  connectSocket: (host, port, {timeout}) {
    recorder.events.add('tcp $host:$port');
    return connect(host, port);
  },
  // Never reached in these tests: no SRV records are ever returned, so the
  // socket is never upgraded to TLS.
  secureSocket: (socket, {host, supportedProtocols, onBadCertificate}) async =>
      throw UnsupportedError('not reached'),
);

void main() {
  test(
    'a server that answers on its own address is never looked up in DNS',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((socket) => socket.destroy());

      final recorder = _Recorder();
      final wrapper = _wrapper(
        recorder,
        connect: (host, port) =>
            Socket.connect(InternetAddress.loopbackIPv4, server.port),
      );
      addTearDown(wrapper.destroy);

      expect(await wrapper.connect('example.org'), isTrue);

      // The whole privacy argument for the inverted order rests on this.
      expect(recorder.queries, isEmpty);
      expect(recorder.events, ['tcp example.org:5222']);
    },
  );

  test('DNS is consulted only after the direct address has failed', () async {
    final recorder = _Recorder();
    final wrapper = _wrapper(
      recorder,
      connect: (host, port) async => throw const SocketException('refused'),
    );
    addTearDown(wrapper.destroy);

    expect(await wrapper.connect('example.org'), isFalse);

    expect(recorder.events, [
      // Pass 1 — the direct address, and nothing else. This is the path the
      // client walked before SRV support existed.
      'tcp example.org:5222',
      // Pass 2 — XEP-0368 (direct TLS) then RFC 6120 (STARTTLS), and finally
      // the same direct address once more, because moxxmpp's RFC 6120 lookup
      // always ends in its fallback. One redundant dial, at the end of a
      // sequence that has already failed twice; the alternative is a private
      // method we cannot reach from here.
      'srv _xmpps-client._tcp.example.org',
      'srv _xmpp-client._tcp.example.org',
      'tcp example.org:5222',
    ]);
  });

  test('an explicit host skips discovery entirely', () async {
    final recorder = _Recorder();
    final wrapper = _wrapper(
      recorder,
      connect: (host, port) async => throw const SocketException('refused'),
    );
    addTearDown(wrapper.destroy);

    expect(
      await wrapper.connect('example.org', host: 'other.example', port: 5223),
      isFalse,
    );

    // The user named a host and a port; guessing a different one would
    // override an explicit instruction.
    expect(recorder.queries, isEmpty);
    expect(recorder.events, ['tcp other.example:5223']);
  });

  test('a domain that only answers behind SRV is reached', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((socket) => socket.destroy());

    final recorder = _Recorder();
    final wrapper = SrvFallbackSocketWrapper(
      srvLookup: (name) async {
        recorder.events.add('srv $name');
        // Both `_xmpps-client` (direct TLS) and `_xmpp-client` point here; the
        // TLS stub refuses so the plain path is the one that succeeds.
        return [MoxSrvRecord(0, 0, 'srv.example.org', server.port)];
      },
      connectSocket: (host, port, {timeout}) async {
        recorder.events.add('tcp $host:$port');
        // The JID domain itself has no listener; only the SRV target does.
        if (host == 'example.org') throw const SocketException('refused');
        return Socket.connect(InternetAddress.loopbackIPv4, server.port);
      },
      secureSocket:
          (socket, {host, supportedProtocols, onBadCertificate}) async {
            recorder.events.add('direct-tls $host');
            socket.destroy();
            throw const HandshakeException('direct TLS refused');
          },
    );
    addTearDown(wrapper.destroy);

    expect(await wrapper.connect('example.org'), isTrue);

    expect(recorder.events, [
      'tcp example.org:5222',
      'srv _xmpps-client._tcp.example.org',
      'tcp srv.example.org:${server.port}',
      'direct-tls example.org',
      'srv _xmpp-client._tcp.example.org',
      'tcp srv.example.org:${server.port}',
    ]);
  });

  test('a suppressed lookup still hands back a list the base class can sort', () async {
    // `TCPSocketWrapper` sorts the records in place. An unmodifiable list here
    // throws from inside `connect`, before a single byte is sent.
    final recorder = _Recorder();
    final wrapper = _wrapper(
      recorder,
      connect: (host, port) async => throw const SocketException('refused'),
    );
    addTearDown(wrapper.destroy);

    final records = await wrapper.srvQuery(
      '_xmpp-client._tcp.example.org',
      false,
    );

    expect(records, isEmpty);
    expect(() => records.sort((a, b) => 0), returnsNormally);
  });
}
