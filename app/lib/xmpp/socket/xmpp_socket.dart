// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Platform-swapped XMPP transport (same pattern as database_connection):
//   native → TCP (+ SOCKS5)
//   web    → RFC 7395 WebSocket (+ XEP-0156 host-meta)

export 'package:resonchat/xmpp/socket/xmpp_socket_io.dart'
    if (dart.library.js_interop) 'package:resonchat/xmpp/socket/xmpp_socket_web.dart';
