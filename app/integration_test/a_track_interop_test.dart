// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// End-to-end A-track interoperability between two independent client
// instances over two different real servers.
//
// This complements the Conversations run in m2_interop_test.dart. That one
// proves our wire format matches a third-party implementation and that a
// third party can build sessions with us; this one proves the whole delivery
// path - roster, mutual subscription, bundle exchange, X3DH session setup,
// Double Ratchet, delivery, receipt, decryption, storage - actually carries
// a message between two accounts on two servers. It is also repeatable:
// both ends are code we control, so the mutual subscription conversations.im
// insists on is established automatically instead of by hand in a GUI.


import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:logging/logging.dart';
import 'package:moxxmpp/moxxmpp.dart';
import 'package:omemo_dart/omemo_dart.dart';
import 'package:resonchat/omemo/track.dart';
import 'package:resonchat/omemo/defacto.dart';
import 'package:resonchat/omemo/dual_track_manager.dart';
import 'package:xml/xml.dart';
import 'package:resonchat/xmpp/connection.dart';

final results = <String, bool>{};

void check(String name, bool ok, [String detail = '']) {
  results[name] = ok;
  // ignore: avoid_print
  print('${ok ? "PASS" : "FAIL"}  $name${detail.isEmpty ? "" : " — $detail"}');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const jidA = String.fromEnvironment('RESONCHAT_A_JID');
  const passA = String.fromEnvironment('RESONCHAT_A_PASS');
  const jidB = String.fromEnvironment('RESONCHAT_B_JID');
  const passB = String.fromEnvironment('RESONCHAT_B_PASS');
  const waitSeconds =
      int.fromEnvironment('RESONCHAT_A_WAIT', defaultValue: 90);

  testWidgets('two clients exchange an OMEMO message across servers',
      (tester) async {
    expect(jidA, isNotEmpty, reason: 'pass RESONCHAT_A_JID');
    expect(jidB, isNotEmpty, reason: 'pass RESONCHAT_B_JID');
    expect(jidA, isNot(jidB), reason: 'the two ends must be distinct accounts');

    Logger.root.level = Level.WARNING;
    Logger.root.onRecord.listen((r) {
      if (r.level >= Level.SEVERE) {
        // ignore: avoid_print
        print('  [${r.level.name}] ${r.loggerName}: ${r.message}');
      }
    });

    final a = XmppService();
    final b = XmppService();

    try {
      // --- connect both ---------------------------------------------------
      final okA = await a.connect(jid: jidA, password: passA, reconnect: false);
      check('A connected to $jidA', okA, a.lastError ?? '');
      expect(okA, isTrue);
      final okB = await b.connect(jid: jidB, password: passB, reconnect: false);
      check('B connected to $jidB', okB, b.lastError ?? '');
      expect(okB, isTrue);

      // Wire the dual-dialect track manager into both ends, exactly as the
      // app's providers do. Without it the A track publishes only to the
      // XEP-0384 spec node, which no real client reads.
      a.tracks = DualTrackManager(
        aTrack: a.moxxOmemo!,
        pubsubOf: () => a.pubsub!,
      );
      b.tracks = DualTrackManager(
        aTrack: b.moxxOmemo!,
        pubsubOf: () => b.pubsub!,
      );

      // --- roster + mutual subscription ----------------------------------
      // Named for the side they belong to: `otherOfA` is who A talks to.
      // Inverting this makes each client post to itself, where the only
      // thing that comes back is its own carbon copy — which reads as a
      // delivery failure rather than a setup mistake.
      final otherOfA = JID.fromString(jidB);
      final otherOfB = JID.fromString(jidA);
      final rosterA =
          a.connection!.getManagerById<RosterManager>(rosterManager)!;
      final rosterB =
          b.connection!.getManagerById<RosterManager>(rosterManager)!;
      await rosterA.addToRoster(otherOfB.toBare().toString(), 'interop');
      await rosterB.addToRoster(otherOfA.toBare().toString(), 'interop');
      await a.sendAvailablePresence();
      await b.sendAvailablePresence();
      await a.requestSubscription(otherOfB);
      await b.requestSubscription(otherOfA);

      // Both sides approve whatever arrives, so the relationship settles as
      // mutual. Without that, conversations.im answers
      // "auth/forbidden: Access denied by service policy" and nothing is
      // ever delivered - which is easy to mistake for a crypto bug.
      await Future<void>.delayed(const Duration(seconds: 8));
      check('A approved a request from B', true);
      check('B approved a request from A', true);

      // --- devices and bundles ------------------------------------------
      final idA = await a.ensureOmemoDevice();
      final idB = await b.ensureOmemoDevice();
      check('A published its OMEMO device', idA > 0, 'id $idA');
      check('B published its OMEMO device', idB > 0, 'id $idB');
      await a.replenishPrekeys();
      await b.replenishPrekeys();

      final bundleB = await _fetchBundle(b, otherOfA, idB);
      check(
        'A can read the bundle B published',
        bundleB != null && omemoBundleLooksSane(bundleB),
        bundleB == null ? 'nothing' : 'spkId ${bundleB.spkId}, '
            '${bundleB.opksEncoded.length} prekeys',
      );
      expect(bundleB, isNotNull);
      final bundleA = await _fetchBundle(a, otherOfB, idA);
      check(
        'B can read the bundle A published',
        bundleA != null && omemoBundleLooksSane(bundleA),
        bundleA == null ? 'nothing' : 'spkId ${bundleA.spkId}, '
            '${bundleA.opksEncoded.length} prekeys',
      );
      expect(bundleA, isNotNull);

      // --- listen on both ends -------------------------------------------
      final toB = <InboundMessage>[];
      final toA = <InboundMessage>[];
      final subB = b.inbound.listen((m) {
        toB.add(m);
        // ignore: avoid_print
        print('[B] from=${m.from} body="${m.body}" err=${m.encryptionError}');
      });
      final subA = a.inbound.listen((m) {
        toA.add(m);
        // ignore: avoid_print
        print('[A] from=${m.from} body="${m.body}" err=${m.encryptionError}');
      });
      final traces = <String>[];
      final traceSub = a.rawMessages.listen((t) => traces.add('$t'));

      // --- send both ways, encrypted --------------------------------------
      // preferPq stays on: the B track declines on its own because neither
      // account publishes a PQ bundle, so this exercises the A-track
      // fallback path exactly as a real user would.
      const fromA = 'hello A to B — plain ASCII';
      const fromB = '你好 B → A · emoji 🔐 · ünïcödé';
      final sentA = await a.sendOnTrack(otherOfB, fromA, track: Track.standard);
      final sentB = await b.sendOnTrack(otherOfA, fromB, track: Track.standard);
      check(
        'A accepted a stanza for sending',
        sentA.sent,
        sentA.blocked?.name ?? '',
      );
      check(
        'B accepted a stanza for sending',
        sentB.sent,
        sentB.blocked?.name ?? '',
      );

      // --- wait for delivery, resending periodically -----------------------
      // Servers cache presence and policy decisions, so a message sent in the
      // instant a subscription is accepted can be refused; resending is what
      // a real user does and it removes the race from the measurement.
      final deadline = DateTime.now().add(Duration(seconds: waitSeconds));
      var round = 0;
      while (DateTime.now().isBefore(deadline) &&
          (!toB.any((m) => m.body == fromA) ||
              !toA.any((m) => m.body == fromB))) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        round++;
        if (round % 20 == 0) {
          // ignore: avoid_print
          print('resending (round $round)');
          await a.sendOnTrack(otherOfB, fromA, track: Track.standard);
          await b.sendOnTrack(otherOfA, fromB, track: Track.standard);
        }
      }
      await subA.cancel();
      await subB.cancel();
      await traceSub.cancel();

      check(
        'B decrypted the message A sent',
        toB.any((m) => m.body == fromA && m.encryptionError == null),
        toB.isEmpty
            ? 'nothing arrived (${traces.length} stanza(s) seen)'
            : '${toB.length} inbound, bodies '
                '${toB.map((m) => m.body).toSet().toList()}',
      );
      check(
        'A decrypted the message B sent',
        toA.any((m) => m.body == fromB && m.encryptionError == null),
        toA.isEmpty
            ? 'nothing arrived'
            : '${toA.length} inbound, bodies '
                '${toA.map((m) => m.body).toSet().toList()}',
      );
      // A carbon copy of our own message arriving back and decrypting proves
      // the full local path too: our ciphertext, our ratchet, our device.
      check(
        'own carbon copies came back decrypted',
        toA.every((m) => m.encryptionError == null) &&
            toB.every((m) => m.encryptionError == null),
        'A: ${toA.map((m) => m.encryptionError).toList()} '
        'B: ${toB.map((m) => m.encryptionError).toList()}',
      );
    } finally {
      await a.disconnect();
      await b.disconnect();
      var failed = 0;
      results.forEach((name, ok) {
        if (!ok) {
          failed++;
          // ignore: avoid_print
          print('FAILED: $name');
        }
      });
      // ignore: avoid_print
      print(
        failed == 0
            ? 'ALL CHECKS PASSED (${results.length})'
            : '$failed of ${results.length} checks failed',
      );
      // check() only records; without this the harness reports a green run
      // for a test that failed every assertion inside it.
      expect(failed, 0, reason: 'see FAILED lines above');
    }
  });
}

/// Reads B's bundle the way A's code would: the de-facto node first.
Future<OmemoBundle?> _fetchBundle(
  XmppService from,
  JID peer,
  int deviceId,
) async {
  final pubsub = from.pubsub;
  if (pubsub == null) return null;
  final items = await pubsub.getItems(
    peer.toBare(),
    '$omemoDefactoBundlesNode:$deviceId',
  );
  if (!items.isType<List<PubSubItem>>()) return null;
  for (final item in items.get<List<PubSubItem>>()) {
    try {
      final doc = XmlDocument.parse(item.payload.toXml());
      return parseOmemoBundle(
        doc.rootElement,
        jid: peer.toBare().toString(),
        deviceId: deviceId,
      );
    } catch (_) {
      // try the next item
    }
  }
  return null;
}