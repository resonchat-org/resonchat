// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Platform-swapped XMPP transport (same pattern as database_connection):
//   native → TCP (+ SOCKS5)
//   web    → RFC 7395 WebSocket (+ XEP-0156 host-meta)

export 'xmpp_socket_io.dart'
    if (dart.library.js_interop) 'xmpp_socket_web.dart';
