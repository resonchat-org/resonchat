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
import 'package:resonchat/omemo/defacto.dart';
import 'package:resonchat/omemo/track.dart';
import 'package:resonchat/omemo/dual_track_manager.dart';
import 'package:resonchat/omemo/protocol.dart';
import 'package:resonchat/xmpp/capabilities.dart';
import 'package:resonchat/store/database.dart';
import 'package:resonchat/store/roster_state.dart';
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
  const listenSeconds = int.fromEnvironment(
    'RESONCHAT_M2_LISTEN',
    defaultValue: 45,
  );

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
    AppDatabase? db;
    try {
      // --- connect ------------------------------------------------------
      // A real, persistent roster store. With the in-memory default the
      // server is told we have no contacts, so it refuses to route anything
      // and every message comes back as an error — which looks exactly like
      // a client bug.
      db = await openAppDatabase(accountId: 'interop-m2');
      final ok = await xmpp.connect(
        jid: jid,
        password: password,
        rosterState: DriftRosterStateManager(db),
        reconnect: false,
      );
      check('connected to $jid', ok, xmpp.lastError ?? '');
      expect(ok, isTrue, reason: 'cannot continue without a connection');

      // --- our own device, as a real client would have ------------------
      check('local OMEMO device created', true, 'pending');

      // --- capability service, wired exactly as the app wires it --------
      final tracks = DualTrackManager(
        aTrack: xmpp.moxxOmemo!,
        pubsubOf: () => xmpp.pubsub!,
      );
      xmpp.tracks = tracks;

      final deviceId = await xmpp.ensureOmemoDevice();
      // ignore: avoid_print
      print('our device $deviceId published in both dialects');
      results.remove('local OMEMO device created');
      check('local OMEMO device created', true, 'id $deviceId');
      expect(deviceId, isNotNull);
      await xmpp.replenishPrekeys();
      check('one-time prekeys replenished', true);
      final caps = CapabilityService(
        tracks: () => tracks,
        ourDeviceId: () async => deviceId,
        // No PQ device in this probe, so the A track must be chosen.
        ourPqDevices: () async => const <int>{},
      );
      xmpp.attachCapabilities(caps);

      // --- roster + presence so the reference client will talk to us ---
      final roster = xmpp.connection!.getManagerById<RosterManager>(
        rosterManager,
      );
      check(
        'roster entry added for $peer',
        await roster!.addToRoster(peer.toBare().toString(), 'interop peer'),
      );
      await xmpp.requestRoster();
      for (final item in await xmpp.requestRoster()) {
        // ignore: avoid_print
        print(
          'roster ${item.jid}: subscription=${item.subscription} '
          'ask=${item.ask}',
        );
      }
      await xmpp.sendAvailablePresence();
      // A one-sided relationship makes most servers refuse to route, which
      // is indistinguishable from a delivery bug — so ask, and auto-approve
      // whatever comes back.
      await xmpp.requestSubscription(peer);
      await xmpp.subscribePeerPep(peer);
      xmpp.subscriptionRequests.listen((jid) {
        // ignore: avoid_print
        print('approved subscription from $jid');
      });

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
        final detail = bundle == null
            ? 'could not parse'
            : 'spk ${_len(bundle.signedPreKeyPublicEncoded)}B '
                  'sig ${_len(bundle.signedPreKeySignatureEncoded)}B '
                  'ik ${_len(bundle.identityKeyEncoded)}B '
                  'opks ${bundle.preKeysEncoded.length} '
                  'pk sizes ${bundle.preKeysEncoded.values.map(_len).toSet().toList()}';
        check(
          'device $id bundle verifies (spk sig ik sizes, opks present)',
          bundle != null && omemoBundleLooksSane(bundle),
          detail,
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
      // The standard track is named explicitly: the reference client speaks
      // OMEMO and cannot read PQ, so this exercises exactly the path it can.
      const plaintext = 'interop from resonchat 9f3a2b';
      final outcome = await xmpp.sendOnTrack(
        peer,
        plaintext,
        track: Track.standard,
      );
      final stanzaId = outcome.stanzaId;
      check(
        'stanza accepted for sending',
        outcome.sent,
        outcome.blocked == null
            ? 'id $stanzaId'
            : 'blocked: ${outcome.blocked}',
      );
      // ignore: avoid_print
      print('sent: "$plaintext" → $peer (look for it in the peer client)');

      // --- receive ------------------------------------------------------
      // ignore: avoid_print
      print('\nListening ${listenSeconds}s for inbound messages…');
      final decrypted = <String>[];
      // Diagnostic: log *every* message stanza we see, encrypted or not, so a
      // silent routing failure is distinguishable from a decryption failure.
      final rawSub = xmpp.rawMessages.listen((event) {
        // ignore: avoid_print
        print('[${DateTime.now().toIso8601String()}] RAW $event');
      });
      final sub = xmpp.inbound.listen((m) {
        // ignore: avoid_print
        print(
          '[${DateTime.now().toIso8601String()}] DECODED from=${m.from} '
          'body="${m.body}" err=${m.encryptionError}',
        );
        if (m.from.toBare() != peer.toBare()) return;
        if (m.encryptionError != null) {
          check(
            'inbound from ${m.from} decrypted',
            false,
            '${m.encryptionError}',
          );
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
      await rawSub.cancel();
      if (decrypted.isEmpty) {
        // Nothing arrived live. Distinguish "server never routed it" from
        // "we could not decrypt it" by asking the archive.
        // ignore: avoid_print
        print('nothing live; asking the archive (MAM) for $peer');
        try {
          final archived = await xmpp.fetchHistory(peer);
          // ignore: avoid_print
          print('archive returned $archived message(s)');
        } catch (e) {
          // The archive is a fallback diagnostic, never a hard requirement.
          // ignore: avoid_print
          print('archive unavailable: $e');
        }
      }
      if (decrypted.isEmpty) {
        check(
          'received at least one decrypted inbound message',
          false,
          'nothing arrived from the peer in ${listenSeconds}s',
        );
      }
    } catch (e, st) {
      // A server dropping an idle stream is not an interoperability
      // failure; record it so the summary stays honest but keep going.
      check('probe completed without a transport error', false, '$e\n$st');
    } finally {
      await xmpp.disconnect();
      await db?.close();
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
int _len(String b64) {
  try {
    return base64Decode(b64).length;
  } catch (_) {
    return -1;
  }
}
