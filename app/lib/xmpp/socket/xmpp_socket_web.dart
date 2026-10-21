// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:moxxmpp/moxxmpp.dart';

/// WebSocket (+ host-meta discovery) for the browser.
///
/// [websocketUrl] forces a `wss://` / `ws://` endpoint; otherwise connect()
/// discovers via XEP-0156 (converse.js style). Implementation lives in
/// moxxmpp (`rfcs/rfc_7395`, `xeps/xep_0156`).
BaseSocketWrapper createXmppSocket({String? websocketUrl}) =>
    WebSocketXmppSocket(preferredUrl: websocketUrl);
