// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Two-account post-quantum interop over real XMPP servers.
//
// This is the check that matters: it publishes B-track bundles on two
// genuinely different accounts, encrypts on one, and decrypts on the other
// through the real PEP + messaging path.
//
//   dart run tool/pq_interop.dart <jidA> <passA> <jidB> <passB>
//
// Credentials come from argv and are never written to disk.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:moxxmpp/moxxmpp.dart';
import 'package:moxxmpp_socket_tcp/moxxmpp_socket_tcp.dart';
import 'package:xml/xml.dart';
import 'package:resonchat/omemo/bundle_codec.dart';
import 'package:resonchat/omemo/dual_track_manager.dart';
import 'package:resonchat/omemo/message_codec.dart';
import 'package:resonchat/omemo/pq_message_layer.dart';
import 'package:resonchat/omemo/pq_session.dart';
import 'package:resonchat/omemo/protocol.dart';
import 'package:resonchat/pq/liboqs_mlkem.dart';

/// Number of failed checks; module-level so [finish] can report it from
/// the `finally` block.
int failures = 0;

/// One logged-in account with its B-track device.
class Peer {
  Peer(this.jid, this.connection, this.pubsub, this.device);

  final JID jid;
  final XmppConnection connection;
  final PubSubManager pubsub;
  final PqDevice device;

  Future<void> close() => connection.disconnect();
}

Future<void> main(List<String> args) async {
  if (args.length < 4) {
    stderr.writeln('usage: pq_interop <jidA> <passA> <jidB> <passB>');
    exitCode = 64;
    return;
  }

  Logger.root.level = Level.WARNING;
  Logger.root.onRecord.listen((r) {
    if (r.level >= Level.WARNING) {
      // ignore: avoid_print
      print('  [${r.level.name}] ${r.loggerName}: ${r.message}');
    }
  });

  final kem = MlKem768Provider.instance.kem;
  // ignore: avoid_print
  print(
    'KEM backend: ${MlKem768Provider.instance.isNative ? 'liboqs (native)' : 'pqcrypto (dart)'}',
  );

  void check(String name, bool ok, [String detail = '']) {
    // ignore: avoid_print
    print(
      '${ok ? "PASS" : "FAIL"}  $name${detail.isEmpty ? "" : " — $detail"}',
    );
    if (!ok) failures++;
  }

  Peer? a;
  Peer? b;
  try {
    a = await connect(args[0], args[1], kem);
    b = await connect(args[2], args[3], kem);
    check('both accounts connected', true, '${a.jid} / ${b.jid}');

    // --- publish B-track bundles -------------------------------------
    final bundleA = await DualTrackManager.deviceFromBundle(
      await publish(a, a.device),
    );
    final bundleB = await DualTrackManager.deviceFromBundle(
      await publish(b, b.device),
    );
    check('bundle A published and readable', bundleA != null);
    check('bundle B published and readable', bundleB != null);
    if (bundleA == null || bundleB == null) return finish();

    // --- capability discovery (the real PEP round-trip) ---------------
    final tracksA = DualTrackManager(
      aTrack: _noopOmemo(),
      pubsubOf: () => a!.pubsub,
    );
    final seen = await tracksA.getPqCapableDevices(b.jid);
    check(
      'A sees B as PQ-capable via PEP',
      seen.contains(b.device.id),
      'saw $seen, expected ${b.device.id}',
    );
    if (!seen.contains(b.device.id)) return finish();

    // --- the PQ round-trip --------------------------------------------
    final sessionsA = PqSessionManager(kem: kem);
    final sessionsB = PqSessionManager(kem: kem);

    final bIk = await b.device.ikDh.pk.getBytes();
    final aIk = await a.device.ikDh.pk.getBytes();
    final layerA = PqMessageLayer(
      ownDevice: a.device,
      sessions: sessionsA,
      senderIkOf: (_, __) async => bIk,
    );
    final layerB = PqMessageLayer(
      ownDevice: b.device,
      sessions: sessionsB,
      senderIkOf: (_, __) async => aIk,
    );

    const plaintext = 'PQ interop over XMPP 🔐';
    final outgoing = await layerA.encrypt(
      plaintext: plaintext,
      recipients: [bundleB],
    );
    check('A produced a PQ message', outgoing != null);
    if (outgoing == null) return finish();

    final entry = outgoing.stanza.keys.single;
    check(
      'handshake carries a full ML-KEM ciphertext',
      entry.kex && entry.pqCiphertexts.isNotEmpty,
      '${entry.pqCiphertexts.length} ciphertext(s)',
    );

    // Round-trip through the XML that would go on the wire.
    final onWire = PqEncryptedMessage.fromXml(outgoing.stanza.toXml());
    check('message survives the XML wire format', onWire.keys.length == 1);

    final recovered = await layerB.decrypt(onWire, senderBareJid: a.device.jid);
    check(
      'B decrypted A\'s PQ message',
      recovered == plaintext,
      recovered == plaintext ? '' : 'got "$recovered"',
    );

    // A second message must reuse the session, not re-handshake.
    final second = await layerA.encrypt(
      plaintext: 'second',
      recipients: [bundleB],
    );
    final secondEntry = second!.stanza.keys.single;
    check('subsequent message skips the handshake', !secondEntry.kex);
    final back2 = await layerB.decrypt(
      PqEncryptedMessage.fromXml(second.stanza.toXml()),
      senderBareJid: a.device.jid,
    );
    check('second message decrypts', back2 == 'second');
  } catch (e, st) {
    failures++;
    // ignore: avoid_print
    print('FAIL  unexpected error: $e\n$st');
  } finally {
    await a?.close();
    await b?.close();
    finish();
  }
}

void finish() {
  // ignore: avoid_print
  print(failures == 0 ? '\nALL CHECKS PASSED' : '\n$failures CHECK(S) FAILED');
  exitCode = failures;
}

/// Connects [jid] and creates its B-track device.
Future<Peer> connect(String jidStr, String password, kem) async {
  final jid = JID.fromString(jidStr);
  final pubsub = PubSubManager();
  final connection = XmppConnection(
    TestingReconnectionPolicy(),
    AlwaysConnectedConnectivityManager(),
    ClientToServerNegotiator(),
    TCPSocketWrapper(false),
  )..connectionSettings = ConnectionSettings(jid: jid, password: password);

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
    throw StateError('could not authenticate $jid');
  }

  final device = await PqDevice.generate(
    jid.toBare().toString(),
    opkCount: 20,
    pqOpkCount: 5,
    kem: kem,
  );
  return Peer(jid, connection, pubsub, device);
}

/// Publishes [device]'s B-track bundle and reads it back from the server.
Future<PqBundle> publish(Peer peer, PqDevice device) async {
  final prekeys = <int, String>{};
  for (final e in device.opks.entries) {
    prekeys[e.key] = _b64(await e.value.pk.getBytes());
  }
  final pqPrekeys = <int, String>{};
  for (final e in device.pqOpks.entries) {
    pqPrekeys[e.key] = _b64(e.value.publicKey);
  }
  final bundle = PqBundle(
    deviceId: device.id,
    jid: peer.jid.toBare().toString(),
    spk: _b64(await device.spk.pk.getBytes()),
    spkId: device.spkId,
    spkSignature: _b64(device.spkSignature),
    ikEncoded: _b64(await device.ikDh.pk.getBytes()),
    prekeys: prekeys,
    pqSpkId: device.pqSpkId,
    pqSpk: _b64(device.pqSpk),
    pqSpkSignature: _b64(device.pqSpkSignature),
    pqPrekeys: pqPrekeys,
  );

  final bare = peer.jid.toBare();

  // Device list first, then the bundle item.
  final listNode = XMLNode.xmlns(
    tag: 'devices',
    xmlns: pomemoDevicesXmlns,
    children: [
      XMLNode(tag: 'device', attributes: {'id': '${device.id}'}),
    ],
  );
  await peer.pubsub.publish(
    bare,
    pomemoDevicesXmlns,
    listNode,
    id: 'current',
    options: const PubSubPublishOptions(accessModel: 'open'),
  );

  await peer.pubsub.publish(
    bare,
    pomemoBundlesXmlns,
    XMLNode.fromString(bundle.toXml().toXmlString()),
    id: '${device.id}',
    options: const PubSubPublishOptions(accessModel: 'open', maxItems: 'max'),
  );

  // Read it back so we prove the server stored what we think it did.
  final item = await peer.pubsub.getItem(
    bare,
    pomemoBundlesXmlns,
    '${device.id}',
  );
  if (!item.isType<PubSubItem>()) {
    throw StateError('server did not return our bundle for ${peer.jid}');
  }
  return PqBundle.fromXml(
    XmlDocument.parse(item.get<PubSubItem>().payload.toXml()).rootElement,
    jidOfBundle: bare.toString(),
  );
}

/// Placeholder A-track manager; the B track does not consult it.
OmemoManager _noopOmemo() => OmemoManager(
  () async => throw StateError('unreachable'),
  (_, _) async => false,
);

String _b64(List<int> bytes) => base64Encode(bytes);
