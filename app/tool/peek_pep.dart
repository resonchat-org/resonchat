// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Dumps a peer's PEP nodes straight from the server, so a capability
// problem can be attributed to the server, our fetch, or our parser.
//
// Usage: dart run tool/peek_pep.dart <jid> <password> <peerJid>

import 'dart:io';

import 'package:logging/logging.dart';
import 'package:moxxmpp/moxxmpp.dart';
import 'package:moxxmpp_socket_tcp/moxxmpp_socket_tcp.dart';

Future<void> main(List<String> args) async {
  if (args.length < 3) {
    stderr.writeln('usage: peek_pep <jid> <password> <peerJid>');
    exitCode = 64;
    return;
  }
  Logger.root.level = Level.FINEST;
  Logger.root.onRecord.listen((r) {
    final m = r.message.toString();
    if (r.level <= Level.FINE) return;
    if (!m.contains('devices') && !m.contains('pubsub')) return;
    // ignore: avoid_print
    print('  [${r.level.name}] ${r.loggerName}: ${m.replaceAll('\n', ' ')}');
  });

  final jid = JID.fromString(args[0]);
  final peer = JID.fromString(args[2]).toBare();
  final pubsub = PubSubManager();
  final connection = XmppConnection(
    TestingReconnectionPolicy(),
    AlwaysConnectedConnectivityManager(),
    ClientToServerNegotiator(),
    TCPSocketWrapper(false),
  )..connectionSettings = ConnectionSettings(jid: jid, password: args[1]);

  await connection.registerManagers([
    PresenceManager(),
    RosterManager(TestingRosterStateManager(null, const [])),
    DiscoManager(const []),
    pubsub,
    MessageManager(),
  ]);
  await connection.registerFeatureNegotiators([
    StartTlsNegotiator(),
    SaslScramNegotiator(30, '', '', ScramHashType.sha256),
    SaslScramNegotiator(20, '', '', ScramHashType.sha512),
    SaslScramNegotiator(10, '', '', ScramHashType.sha1),
    SaslPlainNegotiator(),
    ResourceBindingNegotiator(),
  ]);

  final result = await connection.connect(
    shouldReconnect: false,
    waitUntilLogin: true,
  );
  if (!result.isType<bool>() || !result.get<bool>()) {
    // ignore: avoid_print
    print('could not log in as $jid: $result');
    exitCode = 1;
    return;
  }
  // ignore: avoid_print
  print('logged in as $jid; peeking at $peer\n');

    // Our own roster as the server reports it, forced to a full fetch with an
  // empty ver so a version mismatch cannot hide the answer.
  // ignore: avoid_print
  print('--- own roster (ver="") ---');
  final rosterRaw = await pubsub.getAttributes().sendStanza(
        StanzaDetails(
          Stanza.iq(
            type: 'get',
            children: [
              XMLNode.xmlns(
                tag: 'query',
                xmlns: 'jabber:iq:roster',
                attributes: {'ver': ''},
              ),
            ],
          ),
          shouldEncrypt: false,
        ),
      );
  // ignore: avoid_print
  print(rosterRaw == null
      ? '  (timeout)'
      : '  type=${rosterRaw.attributes['type']}\n'
          '  ${rosterRaw.toXml().replaceAll('\n', '\n  ')}');

for (final node in const [
  'eu.siacs.conversations.axolotl.devicelist',
]) {
  // ignore: avoid_print
  print('--- $node ---');
  // Raw IQ (node attribute on <items>, as XEP-0060 requires) so the
  // server's actual refusal is visible instead of being collapsed into an
  // opaque error type.
  final raw = await pubsub.getAttributes().sendStanza(
        StanzaDetails(
          Stanza.iq(
            type: 'get',
            to: peer.toString(),
            children: [
              XMLNode.xmlns(
                tag: 'pubsub',
                xmlns: 'http://jabber.org/protocol/pubsub',
                children: [
                  XMLNode(tag: 'items', attributes: {'node': node}),
                ],
              ),
            ],
          ),
          shouldEncrypt: false,
        ),
      );
  // ignore: avoid_print
  print(raw == null
      ? '  (timeout)'
      : '  type=${raw.attributes['type']}\n'
          '  ${raw.toXml().replaceAll('\n', '\n  ')}');
}

  await connection.disconnect();
}