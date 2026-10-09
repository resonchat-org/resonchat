// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sends one standard-OMEMO message from our client to a chat that a real
// Conversations instance is expected to display, and prints a unique marker
// so the caller can look for it in the third-party client.
//
// This is the half of the M2 acceptance that the servers here allow: our
// client on jabber.fr reaches conversations.im, and Conversations on the same
// account receives the mirror. Nothing in this test inspects our own
// decryption — the proof is what Conversations renders.
//
// The marker is printed on its own line so a shell script can grep it.

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:logging/logging.dart';
import 'package:moxxmpp/moxxmpp.dart';
import 'package:resonchat/crypto/omemo/track.dart';
import 'package:resonchat/crypto/omemo/dual_track_manager.dart';
import 'package:resonchat/xmpp/connection.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const jid = String.fromEnvironment('RESONCHAT_SEND_JID');
  const password = String.fromEnvironment('RESONCHAT_SEND_PASS');
  const peerJid = String.fromEnvironment('RESONCHAT_SEND_PEER');

  testWidgets('send one encrypted message a real client should display', (
    tester,
  ) async {
    expect(jid, isNotEmpty, reason: 'pass RESONCHAT_SEND_JID');
    expect(peerJid, isNotEmpty, reason: 'pass RESONCHAT_SEND_PEER');

    Logger.root.level = Level.WARNING;

    // A random marker so a stale message cannot be mistaken for a pass.
    final marker =
        'interop-${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(1 << 20)}';
    const unicodeSuffix = ' · 后量子 🔐 ünïcödé';

    final xmpp = XmppService();
    try {
      final ok = await xmpp.connect(
        jid: jid,
        password: password,
        reconnect: false,
      );
      // ignore: avoid_print
      print('connected=$ok ${xmpp.lastError ?? ''}');
      expect(ok, isTrue);

      xmpp.tracks = DualTrackManager(
        aTrack: xmpp.moxxOmemo!,
        pubsubOf: () => xmpp.pubsub!,
      );

      final deviceId = await xmpp.ensureOmemoDevice();
      await xmpp.replenishPrekeys();
      // ignore: avoid_print
      print('device=$deviceId');

      final peer = JID.fromString(peerJid);
      final roster = xmpp.connection!.getManagerById<RosterManager>(
        rosterManager,
      )!;
      await roster.addToRoster(peer.toBare().toString(), 'interop');
      await xmpp.sendAvailablePresence();
      await xmpp.requestSubscription(peer);
      await Future<void>.delayed(const Duration(seconds: 6));

      final body = '$marker$unicodeSuffix';
      final stanzaId = await xmpp.sendOnTrack(
        peer,
        body,
        track: Track.standard,
      );
      // ignore: avoid_print
      print('stanzaId=$stanzaId');

      // Wait long enough for the server to mirror and for the receiving
      // client to render, since the caller checks its screen afterwards.
      await Future<void>.delayed(const Duration(seconds: 20));
    } finally {
      await xmpp.disconnect();
      // ignore: avoid_print
      print('MARKER:$marker');
    }
  });
}
