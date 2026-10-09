// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Listens for a while and prints everything that arrives, decrypted or not.
//
// The mirror image of interop_send_test.dart: it proves the *other* half of
// interoperability — that a message produced by a real client reaches us and
// that we can open it. Both halves matter; only doing outbound would let a
// broken inbound path hide.
//
// Prints `INBOUND-DECODED:<text>` per decrypted message and
// `INBOUND-FAILED:<reason>` per one that could not be opened, plus a
// `TRACE:<raw>` line so a silence can be attributed to routing rather than
// decryption.

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:logging/logging.dart';
import 'package:moxxmpp/moxxmpp.dart' show JID;
import 'package:resonchat/omemo/dual_track_manager.dart';
import 'package:resonchat/store/database.dart';
import 'package:resonchat/store/roster_state.dart';
import 'package:resonchat/xmpp/connection.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const jid = String.fromEnvironment('RESONCHAT_LISTEN_JID');
  const password = String.fromEnvironment('RESONCHAT_LISTEN_PASS');
  const peerJid = String.fromEnvironment('RESONCHAT_LISTEN_PEER');
  const seconds = int.fromEnvironment(
    'RESONCHAT_LISTEN_SECONDS',
    defaultValue: 150,
  );

  testWidgets('receive and decrypt whatever the peer sends', (tester) async {
    expect(jid, isNotEmpty, reason: 'pass RESONCHAT_LISTEN_JID');
    expect(peerJid, isNotEmpty, reason: 'pass RESONCHAT_LISTEN_PEER');

    Logger.root.level = Level.WARNING;

    final db = await openAppDatabase(accountId: 'interop-listen');
    final xmpp = XmppService();
    try {
      final ok = await xmpp.connect(
        jid: jid,
        password: password,
        rosterState: DriftRosterStateManager(db),
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
      await xmpp.subscribePeerPep(JID.fromString(peerJid));
      await xmpp.sendAvailablePresence();

      final decoded = <String>[];
      final failed = <String>[];
      xmpp.rawMessages.listen((t) {
        // ignore: avoid_print
        print('TRACE:$t');
      });
      xmpp.inbound.listen((m) {
        if (m.encryptionError != null) {
          failed.add('${m.from}: ${m.encryptionError}');
          // ignore: avoid_print
          print('INBOUND-FAILED:${m.from}: ${m.encryptionError}');
        } else if (m.body.isNotEmpty) {
          decoded.add(m.body);
          // ignore: avoid_print
          print('INBOUND-DECODED:${m.from}: ${m.body}');
        }
      });

      await Future<void>.delayed(Duration(seconds: seconds));

      // ignore: avoid_print
      print('SUMMARY decoded=${decoded.length} failed=${failed.length}');
    } finally {
      await xmpp.disconnect();
      await db.close();
    }
  });
}
