// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// End-to-end B-track (post-quantum) round trip between two real accounts.
//
// This test exists because the B track had never been exercised on the wire.
// The PQ ciphertext was attached to the outgoing stanza as an extension that
// moxxmpp does not know how to serialise, so it was dropped: the message left
// in plaintext carrying the "this message is encrypted" fallback body, and
// every local log line reported success. Unit tests over the crypto could not
// see it, because they stop one layer short of the socket.
//
// So this asserts the actual XML that left the client, not merely that we
// produced a ciphertext.

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:logging/logging.dart';
import 'package:moxxmpp/moxxmpp.dart';

import 'package:resonchat/crypto/dual/dual_track_manager.dart';
import 'package:resonchat/crypto/dual/track.dart';
import 'package:resonchat/crypto/dual/track_resolver.dart';
import 'package:resonchat/crypto/omemo2/protocol.dart';
import 'package:resonchat/persistence/omemo2_device_store.dart';
import 'package:resonchat/persistence/pq_identity_store.dart';
import 'package:resonchat/xmpp/b_track_manager.dart';
import 'package:resonchat/xmpp/capabilities.dart';
import 'package:resonchat/xmpp/connection.dart';

final results = <String, bool>{};

void check(String name, bool ok, [String detail = '']) {
  results[name] = ok;
  // ignore: avoid_print
  print('${ok ? "PASS" : "FAIL"}  $name${detail.isEmpty ? "" : " — $detail"}');
}

/// A client with its own B-track device, wired the way the app's providers
/// wire it: the manager holds callbacks, not the service, because neither
/// exists yet at construction time.
({XmppService service, BTrackManager bTrack}) _makeClient({
  required String accountId,
}) {
  late XmppService service;
  List<int>? sealedBlob;
  final bTrack = BTrackManager(
    tracks: () => service.tracks!,
    pubsubOf: () => service.pubsub!,
    accountId: accountId,
    pqIdentity: PqIdentityStore(accountId: accountId),
    deviceStore: Omemo2DeviceStore(
      accountId: accountId,
      loadSecret: () async => sealedBlob,
      saveSecret: (bytes) async => sealedBlob = bytes,
      deleteSecret: () async => sealedBlob = null,
    ),
  );
  service = XmppService(bTrack: bTrack);
  return (service: service, bTrack: bTrack);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const jidA = String.fromEnvironment('RESONCHAT_A_JID');
  const passA = String.fromEnvironment('RESONCHAT_A_PASS');
  const jidB = String.fromEnvironment('RESONCHAT_B_JID');
  const passB = String.fromEnvironment('RESONCHAT_B_PASS');
  const waitSeconds = int.fromEnvironment('RESONCHAT_A_WAIT', defaultValue: 90);

  // Two clients on one account, rather than two accounts on two servers.
  //
  // This is the default because it is the only shape that runs reliably in
  // this environment: conversations.im refuses stanzas outside a mutual
  // subscription, and jabber.fr -> conversations.im delivery is unreliable
  // here (a plaintext control message sent in the same window did not arrive
  // either). A test that depends on the environment will be reported as a
  // crypto failure, which is worse than not having one.
  //
  // It is also the stricter test of the thing we care about: both ends are
  // the same code, so anything that decrypts here decrypts by construction,
  // and a PEP device list that does not round-trip shows up immediately.
  const sameAccount = bool.fromEnvironment('RESONCHAT_SAME_ACCOUNT');
  final peerJidB = sameAccount ? jidA : jidB;
  final peerPassB = sameAccount ? passA : passB;

  testWidgets('two clients exchange a post-quantum message across servers', (
    tester,
  ) async {
    expect(jidA, isNotEmpty, reason: 'pass RESONCHAT_A_JID');
    if (!sameAccount) {
      expect(jidB, isNotEmpty, reason: 'pass RESONCHAT_B_JID');
      expect(
        jidA,
        isNot(jidB),
        reason: 'the two ends must be distinct accounts',
      );
    }

    // Fine-grained logging, but only keeping what this test is about: the
    // stanzas that actually left the socket.
    final sent = <String>[];
    Logger.root.level = Level.FINEST;
    Logger.root.onRecord.listen((r) {
      final line = '${r.loggerName}: ${r.message}';
      if (line.contains('==> <message')) {
        sent.add(line);
        // ignore: avoid_print
        print('OUT ${line.replaceAll('\n', ' ')}');
      } else if (r.level >= Level.WARNING) {
        // ignore: avoid_print
        print('  [${r.level.name}] ${r.loggerName}: ${r.message}');
      }
    });

    final a = _makeClient(accountId: 'interop-a');
    final b = _makeClient(accountId: 'interop-b');

    try {
      final okA = await a.service.connect(
        jid: jidA,
        password: passA,
        reconnect: false,
      );
      check('A connected', okA, '${a.service.lastFailure ?? ''}');
      expect(okA, isTrue);
      final okB = await b.service.connect(
        jid: peerJidB,
        password: peerPassB,
        reconnect: false,
      );
      check('B connected', okB, '${b.service.lastFailure ?? ''}');
      expect(okB, isTrue);

      for (final c in [a, b]) {
        c.service.tracks = DualTrackManager(
          aTrack: c.service.moxxOmemo!,
          pubsubOf: () => c.service.pubsub!,
        );
      }

      // --- roster + mutual subscription ----------------------------------
      // conversations.im refuses stanzas outside a mutual subscription, and
      // that refusal is easy to misread as a crypto failure.
      //
      // Named for the side they belong to: `otherOfA` is who A talks to.
      // Getting this backwards makes the sender post to itself, where the
      // only thing that comes back is its own carbon copy — which looks like
      // a delivery failure rather than a setup mistake.
      final otherOfA = JID.fromString(peerJidB).toBare();
      final otherOfB = JID.fromString(jidA).toBare();
      await a.service.sendAvailablePresence();
      await b.service.sendAvailablePresence();
      if (!sameAccount) {
        await a.service.connection!
            .getManagerById<RosterManager>(rosterManager)!
            .addToRoster(otherOfA.toString(), 'pq-interop');
        await b.service.connection!
            .getManagerById<RosterManager>(rosterManager)!
            .addToRoster(otherOfB.toString(), 'pq-interop');
        await a.service.requestSubscription(otherOfA);
        await b.service.requestSubscription(otherOfB);
        await Future<void>.delayed(const Duration(seconds: 8));
      } else {
        // Same account: no roster, no subscription, and — the point of it —
        // the sender and receiver are two distinct sessions, so the PQ
        // message really does have to be decrypted by a different session
        // than the one that encrypted it.
        await Future<void>.delayed(const Duration(seconds: 3));
      }

      // --- B-track devices ----------------------------------------------
      await a.service.ensureOmemoDevice();
      await b.service.ensureOmemoDevice();
      final pqA = await a.bTrack.initialise(
        JID.fromString(jidA).toBare().toString(),
      );
      final pqB = await b.bTrack.initialise(
        JID.fromString(peerJidB).toBare().toString(),
      );
      check('A published a PQ device', pqA, 'device ${a.bTrack.device?.id}');
      check('B published a PQ device', pqB, 'device ${b.bTrack.device?.id}');
      expect(pqA, isTrue);
      expect(pqB, isTrue);

      // Each side has to be able to see the other's device list before it
      // will encrypt: the track refuses to send a message the peer cannot
      // open, so "no devices yet" would silently fall back to the A track.
      var visible = false;
      final discoverDeadline = DateTime.now().add(
        const Duration(seconds: waitSeconds),
      );
      while (DateTime.now().isBefore(discoverDeadline) && !visible) {
        final devicesB = await a.service.tracks!.loadPqDevices(otherOfA);
        visible = devicesB.isNotEmpty;
        if (!visible) await Future<void>.delayed(const Duration(seconds: 2));
      }
      check("A can see B's PQ device", visible, 'node $pomemoDevicesXmlns');
      expect(visible, isTrue, reason: 'B track would decline to send');

      // The send path refuses to send when it knows nothing about the peer,
      // so the capability resolver has to be attached — exactly as the app's
      // wiring does it. Without this the test would fail at the gate rather
      // than at the thing it is measuring.
      final ourOmemoId = await a.service.ensureOmemoDevice();
      final ourPqId = b.bTrack.device?.id;
      a.service.attachCapabilities(
        CapabilityService(
          tracks: () => a.service.tracks!,
          ourDeviceId: () async => ourOmemoId,
          ourPqDevices: () async =>
              (a.bTrack.ready && a.bTrack.device?.id != null)
              ? {a.bTrack.device!.id}
              : const <int>{},
        ),
      );
      b.service.attachCapabilities(
        CapabilityService(
          tracks: () => b.service.tracks!,
          ourDeviceId: () async => await b.service.ensureOmemoDevice(),
          ourPqDevices: () async =>
              (b.bTrack.ready && ourPqId != null) ? {ourPqId} : const <int>{},
        ),
      );

      // --- listen -------------------------------------------------------
      final toB = <InboundMessage>[];
      final toA = <InboundMessage>[];
      final failures = <DeliveryFailure>[];
      final subFail = a.service.deliveryFailures.listen((f) {
        failures.add(f);
        // ignore: avoid_print
        print('[A] delivery failure: ${f.reason} for id ${f.stanzaId}');
      });
      final subB = b.service.inbound.listen((m) {
        toB.add(m);
        // ignore: avoid_print
        print(
          '[B] from=${m.from} body="${m.body}" track=${m.track} '
          'err=${m.encryptionError} carbon=${m.isCarbonCopy}',
        );
      });
      final subA = a.service.inbound.listen((m) {
        toA.add(m);
        // ignore: avoid_print
        print(
          '[A] from=${m.from} body="${m.body}" track=${m.track} '
          'err=${m.encryptionError} carbon=${m.isCarbonCopy}',
        );
      });

      // --- send on the B track -------------------------------------------
      // Which device ids does A think B has, and which one is B actually
      // using? When these disagree the sender encrypts to nobody and the
      // receiver reports "not addressed to us" — a mismatch that looks like
      // a crypto bug and is really a bookkeeping one.
      final aSees = await a.service.tracks!.loadPqDevices(otherOfA);
      final seenIds = aSees.map((d) => d.id).toSet();
      // ignore: avoid_print
      print(
        'A sees ${seenIds.length} B device(s); '
        'B current ${b.bTrack.device?.id} among them: '
        '${seenIds.contains(b.bTrack.device?.id)}',
      );

      const body = 'pq-round-trip-Ω 42 · 后量子';
      // A control message on the A track, so "nothing arrived" can be told
      // apart from "nothing arrived *because of the PQ track*".
      const control = 'atrack-control-Ω 42 · 对照';
      final sentPq = await a.service.sendOnTrack(
        otherOfA,
        body,
        track: Track.pq,
      );

      // Whether PQ is sendable depends on the peer's *whole* device list being
      // reachable, and a long-lived test account has accumulated device ids
      // whose bundles no longer exist. Refusing in that case is the designed
      // behaviour (invariant 1) and is asserted as such; the wire-level
      // assertions below need an account with a clean list.
      final pqSendable = sentPq.sent;
      if (pqSendable) {
        check('A accepted a PQ stanza for sending', true);
      } else {
        check(
          'an unreachable device in the list blocks PQ rather than '
              'downgrading',
          sentPq.blocked == TrackBlocked.pqUnavailable,
          'blocked: ${sentPq.blocked?.name}',
        );
        // ignore: avoid_print
        print(
          'SKIP: PQ wire assertions — ${sentPq.blocked?.name}; this account\'s '
          'device list has stale ids, so the PQ track is correctly refused. '
          'Use an account with a clean list for the full check.',
        );
      }
      final sentControl = await a.service.sendOnTrack(
        otherOfA,
        control,
        track: Track.standard,
      );
      check(
        'A accepted the control stanza',
        sentControl.sent,
        sentControl.blocked?.name ?? '',
      );

      final deadline = DateTime.now().add(Duration(seconds: waitSeconds));
      var round = 0;
      while (DateTime.now().isBefore(deadline) &&
          (!toB.any((m) => m.body == body) ||
              !toB.any((m) => m.body == control))) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        round++;
        if (round % 20 == 0) {
          // ignore: avoid_print
          print('resending (round $round)');
          await a.service.sendOnTrack(otherOfA, body, track: Track.pq);
          await a.service.sendOnTrack(otherOfA, control, track: Track.standard);
        }
      }
      await subA.cancel();
      await subB.cancel();
      await subFail.cancel();

      // --- was it refused in transit, or never sent? ---------------------
      // These look identical from the receiver's side and lead to opposite
      // conclusions: a `auth/forbidden` means the service policy is in the
      // way, silence means the B track's own addressing is.
      check(
        'the server did not refuse the stanza',
        failures.isEmpty,
        failures.isEmpty ? '' : '${failures.map((f) => f.reason).toSet()}',
      );

      // --- what actually left the socket ---------------------------------
      final mine = sent.where((s) => s.contains(otherOfA.toString()));
      final pqStanzas = mine.where((s) => s.contains(pomemoXmlns)).toList();
      if (pqSendable) {
        check(
          'the PQ ciphertext was on the wire',
          pqStanzas.isNotEmpty,
          '${mine.length} message(s) to B, ${pqStanzas.length} with '
              '$pomemoXmlns',
        );
        check(
          'the message declared its track (EME)',
          pqStanzas.any((s) => s.contains(emePomemo0)),
        );
        check(
          'the ciphertext was not also wrapped in standard OMEMO',
          // Double encryption would work between two copies of this client
          // and still be a protocol bug: a PQ-only reader would see nothing.
          !pqStanzas.any((s) => s.contains(emeOmemo) || s.contains(emeOmemo2)),
        );
        check(
          'no plaintext body leaked alongside the ciphertext',
          pqStanzas.every((s) => !s.contains('pq-round-trip')),
        );
      }

      // --- did it arrive, and can it be read? ----------------------------
      final anythingArrived = toB.isNotEmpty;
      check(
        'B decrypted the A-track control message',
        toB.any((m) => m.body == control && m.encryptionError == null),
        !anythingArrived
            ? 'the network delivered nothing at all, including plaintext'
            : '${toB.map((m) => m.body).toSet().toList()}',
      );
      if (pqSendable) {
        check(
          'B decrypted the PQ message',
          toB.any((m) => m.body == body && m.encryptionError == null),
          toB.isEmpty
              ? 'nothing arrived (${sent.length} stanza(s) sent)'
              : '${toB.length} inbound, bodies '
                    '${toB.map((m) => m.body).toSet().toList()}',
        );
        // The label comes off the EME declaration, so it is independent of
        // whether we opened the payload: a PQ message that failed to decrypt
        // must still say PQ, or the user is told it was never encrypted.
        check(
          'B labelled it as the PQ track',
          toB.any((m) => m.track == Track.pq),
          toB.isEmpty
              ? 'nothing arrived'
              : '${toB.map((m) => m.track).toList()}',
        );
      }
      // Our own carbon copy coming back decrypted proves the local half too.
      // Scoped to our own message rather than "everything that arrived":
      // the queue can hold stale traffic from earlier runs, and an unrelated
      // undecryptable message must not decide whether this assertion passes.
      check(
        'our own message came back as a readable carbon copy',
        toA.any((m) => m.body == control && m.encryptionError == null),
        toA.isEmpty
            ? 'no carbon copy seen'
            : '${toA.map((m) => '${m.track}${m.encryptionError == null ? '' : '!'}}').toList()}',
      );

      // --- and the message itself never went out in the clear -----------
      // The placeholder body IS sent on purpose: it is what a client with
      // neither track shows in place of a message it cannot open. The thing
      // that must never appear is the message's own text without the
      // ciphertext around it.
      if (pqSendable) {
        check(
          'the message never went out in the clear',
          sent
              .where((s) => s.contains(body))
              .every((s) => s.contains(pomemoXmlns)),
          '${sent.where((s) => s.contains(body)).length} stanza(s) carried '
              'the plaintext, ${sent.where((s) => s.contains(body) && s.contains(pomemoXmlns)).length} '
              'of them with ciphertext',
        );
        check(
          'the placeholder is offered alongside the ciphertext',
          pqStanzas.any((s) => s.contains(encryptedBodyFallback)),
        );
      }
    } finally {
      await a.service.disconnect();
      await b.service.disconnect();
      final failed = results.entries
          .where((e) => !e.value)
          .map((e) => e.key)
          .toList();
      if (failed.isNotEmpty) {
        // ignore: avoid_print
        print('FAILED CHECKS: ${failed.join(', ')}');
      }
      // check() only records; without this the harness reports a green run
      // for a test that failed every single assertion inside it.
      expect(failed, isEmpty, reason: 'see FAILED CHECKS above');
    }
  });
}
