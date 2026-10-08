// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Browser network path: HTTP uses the browser stack. XMPP TCP/SOCKS is not
// available — connect uses WebSocket + host-meta (see [createXmppSocket]).

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import 'socks5_config.dart';

export 'socks5_config.dart';

/// Web [AppNetwork]: SOCKS prefs are kept for UI/sync, but TCP is unsupported.
class AppNetwork {
  AppNetwork({
    this._config = Socks5ProxyConfig.disabled,
  });

  final _log = Logger('AppNetwork');
  Socks5ProxyConfig _config;
  Future<void>? _loading;

  Socks5ProxyConfig get config => _config;

  set config(Socks5ProxyConfig value) {
    if (_config == value) return;
    _config = value;
    _log.info(
      value.enabled
          ? 'SOCKS5 proxy stored (${value.host}:${value.port}); '
              'ignored on web (browser networking)'
          : 'SOCKS5 proxy off',
    );
  }

  Future<void> loadFrom(Socks5ConfigLoader loader) {
    final future = () async {
      config = await loader();
    }();
    _loading = future;
    return future.whenComplete(() {
      if (identical(_loading, future)) _loading = null;
    });
  }

  Future<void> waitUntilReady() async {
    final loading = _loading;
    if (loading != null) await loading;
  }

  /// Browser [http.Client] (no custom TCP / SOCKS).
  http.Client createHttpClient() => http.Client();
}

final appNetwork = AppNetwork();
