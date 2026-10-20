// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Unified outbound network path (Conversations `SocksSocketFactory` +
// `HttpConnectionManager.getProxy`): every TCP and HTTP hop goes through
// [openTcp], so SOCKS5 is configured once instead of per call site.

import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:logging/logging.dart';

import 'package:resonchat/net/socks5.dart';
import 'package:resonchat/net/socks5_config.dart';

/// App-wide connector: XMPP TCP and HTTP file PUT/GET both call [openTcp].
class AppNetwork {
  AppNetwork({this._config = Socks5ProxyConfig.disabled});

  final _log = Logger('AppNetwork');
  Socks5ProxyConfig _config;

  /// In-flight boot load from the database (auto-login must wait for this).
  Future<void>? _loading;

  Socks5ProxyConfig get config => _config;

  set config(Socks5ProxyConfig value) {
    if (_config == value) return;
    _config = value;
    _log.info(
      value.enabled
          ? 'SOCKS5 proxy on ${value.host}:${value.port}'
          : 'SOCKS5 proxy off',
    );
  }

  /// Apply saved prefs **before** any XMPP connect (call from [main]).
  Future<void> loadFrom(Socks5ConfigLoader loader) {
    final future = () async {
      config = await loader();
    }();
    _loading = future;
    return future.whenComplete(() {
      if (identical(_loading, future)) _loading = null;
    });
  }

  /// Wait until [loadFrom] (if any) has finished applying prefs.
  Future<void> waitUntilReady() async {
    final loading = _loading;
    if (loading != null) await loading;
  }

  /// Plain TCP to [host]:[port], optionally via SOCKS5 CONNECT.
  Future<Socket> openTcp(String host, int port, {Duration? timeout}) async {
    await waitUntilReady();
    final cfg = _config;
    final wait = timeout ?? const Duration(seconds: 15);
    if (!cfg.enabled) {
      return Socket.connect(host, port, timeout: wait);
    }
    final proxyHost = cfg.host.trim().isEmpty ? '127.0.0.1' : cfg.host.trim();
    final proxy = await Socket.connect(proxyHost, cfg.port, timeout: wait);
    final socks = SocksSocket(proxy);
    try {
      await socks5Handshake(socks, destination: host, port: port);
      return socks;
    } catch (e) {
      _log.warning('SOCKS5 CONNECT $host:$port via $proxyHost:${cfg.port}: $e');
      await socks.close();
      rethrow;
    }
  }

  /// TLS for a socket from [openTcp] (plain or [SocksSocket]).
  Future<SecureSocket> secureSocket(
    Socket socket, {
    dynamic host,
    List<String>? supportedProtocols,
    bool Function(X509Certificate certificate)? onBadCertificate,
  }) {
    if (socket is SocksSocket) {
      return socket.secure(
        host: host,
        supportedProtocols: supportedProtocols,
        onBadCertificate: onBadCertificate,
      );
    }
    return SecureSocket.secure(
      socket,
      host: host,
      supportedProtocols: supportedProtocols,
      onBadCertificate: onBadCertificate,
    );
  }

  /// `package:http` client whose sockets come from [openTcp].
  http.Client createHttpClient() {
    final io = HttpClient();
    io.connectionFactory = (uri, proxyHost, proxyPort) async {
      final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);
      Socket? raw;
      final future = () async {
        raw = await openTcp(uri.host, port);
        if (uri.scheme == 'https') {
          return secureSocket(raw!, host: uri.host);
        }
        return raw!;
      }();
      return ConnectionTask.fromSocket(future, () {
        raw?.destroy();
      });
    };
    return IOClient(io);
  }
}

/// Process-wide instance; settings and XmppService both talk to this.
final appNetwork = AppNetwork();
