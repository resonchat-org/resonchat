// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// SOCKS5 CONNECT (RFC 1928), Conversations `SocksSocketFactory` style:
// no authentication, domain/IP destination, DNS at the proxy when given a name.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// [Socket] wrapper that takes the one underlying subscription via
/// [asBroadcastStream], so SOCKS handshake and later XMPP/TLS reads share it.
///
/// Call [secure] for TLS — [SecureSocket.secure] cannot unwrap this class.
class SocksSocket extends Stream<Uint8List> implements Socket {
  SocksSocket(this._inner) : _broadcast = _inner.asBroadcastStream();

  final Socket _inner;
  final Stream<List<int>> _broadcast;

  Future<SecureSocket> secure({
    dynamic host,
    List<String>? supportedProtocols,
    bool Function(X509Certificate certificate)? onBadCertificate,
  }) {
    return SecureSocket.secure(
      _inner,
      host: host,
      supportedProtocols: supportedProtocols,
      onBadCertificate: onBadCertificate,
    );
  }

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return _broadcast
        .map(Uint8List.fromList)
        .listen(
          onData,
          onError: onError,
          onDone: onDone,
          cancelOnError: cancelOnError,
        );
  }

  @override
  Encoding get encoding => _inner.encoding;
  @override
  set encoding(Encoding value) => _inner.encoding = value;

  @override
  void add(List<int> data) => _inner.add(data);
  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);
  @override
  Future addStream(Stream<List<int>> stream) => _inner.addStream(stream);
  @override
  Future close() => _inner.close();
  @override
  void destroy() => _inner.destroy();
  @override
  Future get done => _inner.done;
  @override
  Future flush() => _inner.flush();
  @override
  void write(Object? object) => _inner.write(object);
  @override
  void writeAll(Iterable objects, [String separator = '']) =>
      _inner.writeAll(objects, separator);
  @override
  void writeCharCode(int charCode) => _inner.writeCharCode(charCode);
  @override
  void writeln([Object? object = '']) => _inner.writeln(object);

  @override
  bool setOption(SocketOption option, bool enabled) =>
      _inner.setOption(option, enabled);
  @override
  Uint8List getRawOption(RawSocketOption option) => _inner.getRawOption(option);
  @override
  void setRawOption(RawSocketOption option) => _inner.setRawOption(option);

  @override
  int get port => _inner.port;
  @override
  InternetAddress get address => _inner.address;
  @override
  int get remotePort => _inner.remotePort;
  @override
  InternetAddress get remoteAddress => _inner.remoteAddress;
}

/// Negotiates SOCKS5 CONNECT on [proxy].
Future<void> socks5Handshake(
  SocksSocket proxy, {
  required String destination,
  required int port,
}) async {
  final reader = _SocketByteReader(proxy);
  try {
    proxy.add(const [0x05, 0x01, 0x00]);
    await proxy.flush();
    final greet = await reader.readExact(2);
    if (greet[0] != 0x05 || greet[1] != 0x00) {
      throw const Socks5Exception('SOCKS5 handshake rejected');
    }

    proxy.add(buildSocks5ConnectRequest(destination, port));
    await proxy.flush();

    final head = await reader.readExact(4);
    if (head[0] != 0x05) {
      throw Socks5Exception('unknown SOCKS version ${head[0]}');
    }
    final status = head[1];
    final atyp = head[3];
    await _skipBoundAddress(reader, atyp);
    await reader.readExact(2); // BND.PORT

    if (status != 0x00) {
      throw Socks5Exception(_statusMessage(status));
    }
  } finally {
    // Drop the handshake subscription so it cannot steal later traffic.
    await reader.cancel();
  }
}

/// Wire bytes for a CONNECT request (no auth), for tests.
Uint8List buildSocks5ConnectRequest(String destination, int port) {
  if (port < 0 || port > 0xffff) {
    throw ArgumentError.value(port, 'port');
  }
  final ip = InternetAddress.tryParse(destination);
  final builder = BytesBuilder(copy: false);
  if (ip != null && ip.type == InternetAddressType.IPv4) {
    builder.add([0x05, 0x01, 0x00, 0x01]);
    builder.add(ip.rawAddress);
  } else if (ip != null && ip.type == InternetAddressType.IPv6) {
    builder.add([0x05, 0x01, 0x00, 0x04]);
    builder.add(ip.rawAddress);
  } else {
    final host = utf8.encode(destination);
    if (host.length > 255) {
      throw ArgumentError('destination too long for SOCKS5');
    }
    builder.add([0x05, 0x01, 0x00, 0x03, host.length]);
    builder.add(host);
  }
  builder.add([(port >> 8) & 0xff, port & 0xff]);
  return builder.takeBytes();
}

Future<void> _skipBoundAddress(_SocketByteReader reader, int atyp) async {
  if (atyp == 0x01) {
    await reader.readExact(4);
  } else if (atyp == 0x04) {
    await reader.readExact(16);
  } else if (atyp == 0x03) {
    final len = (await reader.readExact(1))[0];
    await reader.readExact(len);
  } else {
    throw Socks5Exception('unknown SOCKS address type $atyp');
  }
}

String _statusMessage(int status) {
  return switch (status) {
    0x01 => 'SOCKS5 general failure',
    0x02 => 'SOCKS5 connection not allowed',
    0x03 => 'SOCKS5 network unreachable',
    0x04 => 'SOCKS5 host unreachable',
    0x05 => 'SOCKS5 connection refused',
    0x06 => 'SOCKS5 TTL expired',
    0x07 => 'SOCKS5 command not supported',
    0x08 => 'SOCKS5 address type not supported',
    _ => 'SOCKS5 status 0x${status.toRadixString(16)}',
  };
}

class _SocketByteReader {
  _SocketByteReader(Stream<List<int>> stream)
    : _iterator = StreamIterator<List<int>>(stream);

  final StreamIterator<List<int>> _iterator;
  final List<int> _buf = <int>[];

  Future<Uint8List> readExact(int n) async {
    while (_buf.length < n) {
      if (!await _iterator.moveNext()) {
        throw const Socks5Exception('SOCKS5 reply truncated');
      }
      _buf.addAll(_iterator.current);
    }
    final out = Uint8List.fromList(_buf.sublist(0, n));
    _buf.removeRange(0, n);
    return out;
  }

  Future<void> cancel() => _iterator.cancel();
}

class Socks5Exception implements IOException {
  const Socks5Exception(this.message);
  final String message;
  @override
  String toString() => message;
}
