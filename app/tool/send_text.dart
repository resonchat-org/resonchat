// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sends one plain-text chat message with no OMEMO involved, and reports
// everything about the subscription state.
//
// Purpose: to tell "the server will not route between these accounts" apart
// from "our client mishandles the stanza". If this can deliver and ours
// cannot, the bug is ours; if this cannot either, it is routing.
//
// Usage: dart run tool/send_text.dart <jid> <password> <peerJid> <text>

import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:moxxmpp/moxxmpp.dart';
import 'package:moxxmpp_socket_tcp/moxxmpp_socket_tcp.dart';

Future<void> main(List<String> args) async {
  if (args.length < 4) {
    stderr.writeln('usage: send_text <jid> <password> <peerJid> <text>');
    exitCode = 64;
    return;
  }
  Logger.root.level = Level.FINEST;
  Logger.root.onRecord.listen((r) {
    final m = r.message.toString();
    if (m.startsWith('==>') || m.startsWith('<==')) {
      // ignore: avoid_print
      print('  ${r.message.toString().replaceAll('\n', ' ')}');
    }
  });

  final jid = JID.fromString(args[0]);
  final peer = JID.fromString(args[2]);
  final roster = RosterManager(TestingRosterStateManager(null, const []));
  final mm = MessageManager();
  final connection = XmppConnection(
    TestingReconnectionPolicy(),
    AlwaysConnectedConnectivityManager(),
    ClientToServerNegotiator(),
    TCPSocketWrapper(false),
  )..connectionSettings = ConnectionSettings(jid: jid, password: args[1]);

  await connection.registerManagers([
    PresenceManager(),
    roster,
    DiscoManager(const []),
    mm,
  ]);
  await connection.registerFeatureNegotiators([
    StartTlsNegotiator(),
    SaslScramNegotiator(30, '', '', ScramHashType.sha256),
    SaslScramNegotiator(10, '', '', ScramHashType.sha1),
    SaslPlainNegotiator(),
    RosterFeatureNegotiator(),
    ResourceBindingNegotiator(),
  ]);

  final result = await connection.connect(
    shouldReconnect: false,
    waitUntilLogin: true,
  );
  if (!result.isType<bool>() || !result.get<bool>()) {
    // ignore: avoid_print
    print('login failed: $result');
    exitCode = 1;
    return;
  }

  final rm = connection.getManagerById<RosterManager>(rosterManager)!;
  final added = await rm.addToRoster(peer.toBare().toString(), 'probe');
  // ignore: avoid_print
  print('roster add: $added');

  final presence = connection.getManagerById<PresenceManager>(presenceManager)!;
  await presence.requestSubscription(peer.toBare());
  // ignore: avoid_print
  print('sent subscribe to ${peer.toBare()}');

  final subscriptionRequests = <JID>[];
  connection.asBroadcastStream().listen((event) {
    if (event is SubscriptionRequestReceivedEvent) {
      subscriptionRequests.add(event.from);
      // ignore: avoid_print
      print('incoming subscription from ${event.from}');
    }
  });

  await Future<void>.delayed(const Duration(seconds: 5));
  for (final from in subscriptionRequests) {
    await presence.acceptSubscriptionRequest(from.toBare());
    // ignore: avoid_print
    print('approved ${from.toBare()}');
  }

  final rosterResult = await rm.requestRoster();
  // ignore: avoid_print
  print('roster result type: ${rosterResult.runtimeType}');
  if (rosterResult.isType<RosterRequestResult>()) {
    for (final item in rosterResult.get<RosterRequestResult>().items) {
      // ignore: avoid_print
      print('  ${item.jid}: subscription=${item.subscription} ask=${item.ask}');
    }
  } else {
    // ignore: avoid_print
    print('  roster error: ${rosterResult.get<RosterError>()}');
  }

  await mm.sendMessage(
    peer.toBare(),
    TypedMap<StanzaHandlerExtension>.fromList([
      MessageBodyData(args[3]),
      MessageIdData('probe-${DateTime.now().millisecondsSinceEpoch}'),
    ]),
    type: 'chat',
  );
  // ignore: avoid_print
  print('sent plaintext to ${peer.toBare()}: "${args[3]}"');

  // Stay online a little so the delivery can land while we are listening.
  final got = <String>[];
  connection.asBroadcastStream().listen((event) {
    if (event is MessageEvent) {
      final body = event.get<MessageBodyData>()?.body;
      got.add('${event.from}: $body');
      // ignore: avoid_print
      print(
        'INBOUND from=${event.from} to=${event.to} type=${event.type} '
        'id=${event.id} error=${event.error} body=$body',
      );
      if (event.error != null) {
        // ignore: avoid_print
        print('  SERVER REFUSAL: ${event.error}');
      }
    }
  });
  await Future<void>.delayed(const Duration(seconds: 25));
  // ignore: avoid_print
  print('received ${got.length} inbound message(s)');

  await connection.disconnect();
}
