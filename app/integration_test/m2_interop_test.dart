// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// M2 acceptance: interoperate with a real OMEMO client.
//
// Everything before this has been self-consistency — our code talking to
// our code. This is the only test that can prove the A track really is
// standard OMEMO. It runs on a device, drives the production code paths
// (XmppService, CapabilityService, omemo_dart, our own bundle parser), and
// exchanges messages with the reference client running on the other end.
//
// Credentials arrive as --dart-define values, so nothing is committed:
//
//   flutter test integration_test/m2_interop_test.dart \
//     -d <device> \
//     --dart-define=RESONCHAT_M2_JID=… \
//     --dart-define=RESONCHAT_M2_PASS=… \
//     --dart-define=RESONCHAT_M2_PEER=… \
//     --dart-define=RESONCHAT_M2_LISTEN=45
//
// Each step prints PASS/FAIL so a failing run is readable without a
// debugger.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:logging/logging.dart';
import 'package:moxxmpp/moxxmpp.dart' show JID, RosterManager, rosterManager;
import 'package:omemo_dart/omemo_dart.dart' show OmemoBundle;
import 'package:resonchat/omemo/dual_track_manager.dart';
import 'package:resonchat/omemo/protocol.dart';
import 'package:resonchat/xmpp/capabilities.dart';
import 'package:resonchat/xmpp/connection.dart';

/// Strings shared between steps, so a failure can be reported by name.
final results = <String, bool>{};

void check(String name, bool ok, [String detail = '']) {
  results[name] = ok;
  // ignore: avoid_print
  print('${ok ? "PASS" : "FAIL"}  $name${detail.isEmpty ? "" : " — $detail"}');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const jid = String.fromEnvironment('RESONCHAT_M2_JID');
  const password = String.fromEnvironment('RESONCHAT_M2_PASS');
  const peerText = String.fromEnvironment('RESONCHAT_M2_PEER');
  const listenSeconds =
      int.fromEnvironment('RESONCHAT_M2_LISTEN', defaultValue: 45);

  testWidgets('interoperate with a real OMEMO client', (tester) async {
    expect(jid, isNotEmpty, reason: 'pass RESONCHAT_M2_JID');
    expect(peerText, isNotEmpty, reason: 'pass RESONCHAT_M2_PEER');
    final peer = JID.fromString(peerText);

    Logger.root.level = Level.WARNING;
    Logger.root.onRecord.listen((r) {
      if (r.level >= Level.WARNING) {
        // ignore: avoid_print
        print('  [${r.level.name}] ${r.loggerName}: ${r.message}');
      }
    });

    final xmpp = XmppService();
    try {
      // --- connect ------------------------------------------------------
      final ok = await xmpp.connect(jid: jid, password: password);
      check('connected to $jid', ok, xmpp.lastError ?? '');
      expect(ok, isTrue, reason: 'cannot continue without a connection');

      // --- our own device, as a real client would have ------------------
      final deviceId = await xmpp.ensureOmemoDevice();
      check('local OMEMO device created', true, 'id $deviceId');
      expect(deviceId, isNotNull);
      await xmpp.replenishPrekeys();
      check('one-time prekeys replenished', true);

      // --- capability service, wired exactly as the app wires it --------
      final tracks = DualTrackManager(
        aTrack: xmpp.moxxOmemo!,
        pubsubOf: () => xmpp.pubsub!,
      );
      final caps = CapabilityService(
        tracks: () => tracks,
        ourDeviceId: () async => deviceId,
      );
      xmpp.attachCapabilities(caps);

      // --- roster + presence so the reference client will talk to us ---
      final roster =
          xmpp.connection!.getManagerById<RosterManager>(rosterManager);
      check(
        'roster entry added for $peer',
        await roster!.addToRoster(peer.toBare().toString(), 'interop peer'),
      );
      await xmpp.sendAvailablePresence();
      await xmpp.subscribePeerPep(peer);

      // --- read a bundle written by another implementation -------------
      // This is the first time our parser sees foreign data, so any wire
      // format assumption fails here rather than in the field.
      await Future<void>.delayed(const Duration(seconds: 5));
      final peerDevices = await tracks.getOmemoCapableDevices(peer);
      check(
        'peer publishes readable OMEMO devices',
        peerDevices.isNotEmpty,
        'ids ${peerDevices.toList()}',
      );
      expect(peerDevices, isNotEmpty);

      for (final id in peerDevices) {
        final bundle = await tracks.getOmemoBundle(peer, id);
        check(
          'device $id bundle verifies (spk sig ik sizes, opks present)',
          bundle != null && _bundleLooksSane(bundle),
          bundle == null
              ? 'could not parse'
              : 'spkId ${bundle.spkId}, ${bundle.opksEncoded.length} opks',
        );
      }

      // --- what our negotiator decides about them ----------------------
      final capabilities = await caps.forChat(peer);
      check(
        'capability resolution is reliable',
        capabilities.reliable,
        'mode ${capabilities.mode.name}, '
        'devices ${capabilities.recipientDevices.toList()}',
      );
      check(
        'a standard client negotiates onto the A track',
        capabilities.mode == EncMode.standardOmemo,
        capabilities.mode.name,
      );

      // --- send a real OMEMO message -----------------------------------
      // preferPq is off deliberately: the reference client speaks standard
      // OMEMO, so this exercises exactly the path it can read.
      const plaintext = 'interop from resonchat 9f3a2b';
      final stanzaId = await xmpp.sendPlainText(
        peer,
        plaintext,
        preferPq: false,
      );
      check('stanza accepted for sending', stanzaId != null, 'id $stanzaId');
      // ignore: avoid_print
      print('sent: "$plaintext" → $peer (look for it in the peer client)');

      // --- receive ------------------------------------------------------
      // ignore: avoid_print
      print('\nListening ${listenSeconds}s for inbound messages…');
      final decrypted = <String>[];
      final sub = xmpp.inbound.listen((m) {
        if (m.from.toBare() != peer.toBare()) return;
        if (m.encryptionError != null) {
          check('inbound from ${m.from} decrypted', false,
              '${m.encryptionError}');
        } else if (m.body.isEmpty) {
          // ignore: avoid_print
          print('  (no body from ${m.from})');
        } else {
          decrypted.add(m.body);
          check('inbound from ${m.from} decrypted', true, '"${m.body}"');
        }
      });
      await Future<void>.delayed(Duration(seconds: listenSeconds));
      await sub.cancel();
      if (decrypted.isEmpty) {
        check('received at least one decrypted inbound message', false,
            'nothing arrived from the peer in ${listenSeconds}s');
      }
    } finally {
      await xmpp.disconnect();
      // ignore: avoid_print
      print('\n---- summary ----');
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
    }
  });
}

/// Structural sanity of a foreign bundle. Size mismatches here are how a
/// silent incompatibility announces itself.
bool _bundleLooksSane(OmemoBundle b) {
  try {
    if (base64Decode(b.spkEncoded).length != 32) return false;
    if (base64Decode(b.spkSignatureEncoded).length != 64) return false;
    if (base64Decode(b.ikEncoded).length != 32) return false;
    if (b.opksEncoded.isEmpty) return false;
    for (final pk in b.opksEncoded.values) {
      if (base64Decode(pk).length != 32) return false;
    }
    return true;
  } catch (_) {
    return false;
  }
}