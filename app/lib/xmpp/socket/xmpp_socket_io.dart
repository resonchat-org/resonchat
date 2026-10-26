// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:moxxmpp/moxxmpp.dart';
import 'package:moxxmpp/socket_tcp.dart';

import 'package:resonchat/net/app_network.dart';
import 'package:resonchat/xmpp/srv_resolver.dart';

/// TCP (+ optional SOCKS5) for native platforms.
///
/// [websocketUrl] is ignored — desktop/mobile keep Conversations-style TCP.
BaseSocketWrapper createXmppSocket({String? websocketUrl}) =>
    SrvFallbackSocketWrapper(srvLookup: _srvResolver.query);

/// Process-wide, so the rare SRV fallback reuses one HTTP client instead of
/// standing up a connection pool for every login attempt. Its client is created
/// on first query, i.e. only for domains that needed SRV at all.
final _srvResolver = DohSrvResolver(clientFactory: appNetwork.createHttpClient);

/// SRV records for [name], or an empty list. Never throws.
///
/// The list must be **modifiable**: `TCPSocketWrapper` sorts it in place
/// (RFC 2782 ordering), so returning `const []` throws
/// `Unsupported operation: Cannot modify an unmodifiable list` from inside the
/// connect path. Always hand back a fresh growable list.
typedef SrvLookup = Future<List<MoxSrvRecord>> Function(String name);

/// A [TCPSocketWrapper] that consults DNS SRV only after a direct connection
/// has already failed.
///
/// Upstream (and RFC 6120) look up SRV *first*, then fall back to the JID
/// domain. That order costs nothing when SRV comes from the system resolver.
/// Ours does not: this app resolves SRV over DNS-over-HTTPS (see
/// [DohSrvResolver]), which means every connect attempt would hand a third
/// party the XMPP domain the user is signing in to — including for the great
/// majority of servers that answer on their own address and never needed SRV.
///
/// So the order is inverted. The first pass suppresses SRV entirely, which
/// makes the base class walk the exact path it walked before this file existed:
/// `_xep368Connect` finds nothing, `_rfc6120Connect` finds nothing, and
/// `_rfc6120FallbackConnect` dials `<domain>:5222`. Only if that fails is SRV
/// worth a query, and then the second pass runs the full XEP-0368 / RFC 6120
/// discovery on the records we fetched.
///
/// This is monotonic: it can only add reachability. A domain that connected
/// before still connects identically and still sends no DoH query.
///
/// It is also not a downgrade. Trying plaintext port 5222 before direct-TLS SRV
/// records cannot leak a password: the SCRAM and PLAIN negotiators refuse to
/// match on a socket that is not secure, so a server that does not offer
/// STARTTLS fails the login instead of authenticating in the clear.
class SrvFallbackSocketWrapper extends TCPSocketWrapper {
  SrvFallbackSocketWrapper({
    required this.srvLookup,
    TcpSocketConnect? connectSocket,
    TcpSocketSecure? secureSocket,
  }) : super(
         false,
         connectSocket: connectSocket ?? appNetwork.openTcp,
         secureSocket: secureSocket ?? appNetwork.secureSocket,
       );

  final SrvLookup srvLookup;

  /// False until the direct attempt has failed, so a first pass cannot query.
  bool _srvAllowed = false;

  @override
  Future<bool> connect(String domain, {String? host, int? port}) async {
    // A caller-supplied host is an explicit instruction from the user; honour
    // it and do no discovery of any kind.
    if (host != null && port != null) {
      return super.connect(domain, host: host, port: port);
    }

    // Pass 1: no SRV. Identical to connecting before SRV existed.
    _srvAllowed = false;
    if (await super.connect(domain)) return true;

    // Pass 2: the direct address did not work. Now, and only now, ask DNS.
    _srvAllowed = true;
    return super.connect(domain);
  }

  @override
  Future<List<MoxSrvRecord>> srvQuery(String domain, bool dnssec) async {
    // A fresh, growable list either way: the caller sorts it in place.
    if (!_srvAllowed) return <MoxSrvRecord>[];
    // `domain` here is already the full query name, e.g.
    // `_xmpp-client._tcp.example.org`; `dnssec` is ignored — the DoH endpoint
    // either validates or it does not, and we cannot insist on it.
    return srvLookup(domain);
  }
}
