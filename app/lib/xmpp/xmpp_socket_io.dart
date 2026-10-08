// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:moxxmpp/moxxmpp.dart';
import 'package:moxxmpp_socket_tcp/moxxmpp_socket_tcp.dart';

import '../net/app_network.dart';

/// TCP (+ optional SOCKS5) for native platforms.
///
/// [websocketUrl] is ignored — desktop/mobile keep Conversations-style TCP.
BaseSocketWrapper createXmppSocket({String? websocketUrl}) => TCPSocketWrapper(
  false,
  connectSocket: appNetwork.openTcp,
  secureSocket: appNetwork.secureSocket,
);
