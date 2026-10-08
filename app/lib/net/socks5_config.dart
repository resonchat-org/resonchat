// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Shared SOCKS5 prefs model (no dart:io) so web UI can still display settings.

/// SOCKS5 endpoint the user configured (host defaults to loopback).
class Socks5ProxyConfig {
  const Socks5ProxyConfig({
    required this.enabled,
    this.host = '127.0.0.1',
    this.port = 7890,
  });

  final bool enabled;
  final String host;
  final int port;

  static const disabled = Socks5ProxyConfig(enabled: false);

  Socks5ProxyConfig copyWith({
    bool? enabled,
    String? host,
    int? port,
  }) =>
      Socks5ProxyConfig(
        enabled: enabled ?? this.enabled,
        host: host ?? this.host,
        port: port ?? this.port,
      );

  @override
  bool operator ==(Object other) =>
      other is Socks5ProxyConfig &&
      other.enabled == enabled &&
      other.host == host &&
      other.port == port;

  @override
  int get hashCode => Object.hash(enabled, host, port);
}

/// Loads SOCKS5 prefs from storage (used by [AppNetwork.loadFrom]).
typedef Socks5ConfigLoader = Future<Socks5ProxyConfig> Function();
