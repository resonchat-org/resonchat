// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Library-level PQ session interop (closer to monocles than fingerprint-only):
//   * Omemo2Manager Alice↔Bob with ML-DSA via libsignal PqIdentityKeyPair
//     (monocles `org.signal.libsignal.protocol.pqid`) and via pqcrypto
//     (ResonChat `PqIdentityStore`) — both must open each other's ciphertext.
//   * Wire XML (`<encrypted xmlns=urn:monocles:omemo-pq:1>`) round-trip
//     through PqMessageLayer including mandatory `<pq-auth>` / `<commit>`.
//
// Fingerprints matching only proves identity keys; decrypt needs a live
// PQXDH+SPQR session built from a verified bundle.

import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:libsignal/libsignal.dart' as ls;
import 'package:omemo_dart/omemo_dart_omemo2.dart';
import 'package:pqcrypto/pqcrypto.dart';
import 'package:test/test.dart';

import 'package:resonchat/crypto/dual/dual_track_manager.dart';
import 'package:resonchat/crypto/omemo2/bundle_codec.dart';
import 'package:resonchat/crypto/omemo2/message_codec.dart';
import 'package:resonchat/crypto/omemo2/omemo2_bundle_verify.dart';
import 'package:resonchat/crypto/omemo2/pq_message_layer.dart';
import 'package:resonchat/crypto/omemo2/pq_session.dart';
import 'package:resonchat/persistence/database.dart';
import 'package:resonchat/persistence/omemo2_pq_pin_store.dart';
import 'package:resonchat/persistence/pq_identity_store.dart';

class _MemPq implements PqIdentityStore {
  _MemPq(this.pk, this.sk);
  final Uint8List pk;
  final Uint8List sk;
  @override
  String get accountId => 'test';
  @override
  Future<Uint8List> publicKey() async => pk;
  @override
  Future<(Uint8List, Uint8List)> keyPair() async => (pk, sk);
  @override
  Future<Uint8List> sign(Uint8List message) async => MlDsa.sign(
    sk,
    message,
    DilithiumParams.mlDsa87,
    ctx: Uint8List.fromList(utf8.encode(omemo2PqIdContext)),
  );
  @override
  Future<void> clear() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _LibsignalPq implements PqIdentityStore {
  _LibsignalPq(this.pair);
  final ls.PqIdentityKeyPair pair;
  @override
  String get accountId => 'monocles-like';
  @override
  Future<Uint8List> publicKey() async =>
      Uint8List.fromList(pair.publicKey().serialize());
  @override
  Future<(Uint8List, Uint8List)> keyPair() async {
    final ser = pair.serialize();
    // Signing key ‖ verification key — only public half is needed by callers
    // of keyPair() for length checks; sign() uses [pair] directly.
    final pk = pair.publicKey().serialize();
    return (Uint8List.fromList(pk), Uint8List.fromList(ser));
  }

  @override
  Future<Uint8List> sign(Uint8List message) async =>
      Uint8List.fromList(pair.sign(message: message).serialize());
  @override
  Future<void> clear() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<Omemo2Bundle> _publish(Omemo2Device device, PqIdentityStore pq) async {
  await device.ensureStores();
  final ikSerialized = await device.identityPublicSerialized();
  final ikRaw = ikSerialized.sublist(1);
  final spkRaw = await device.spk.pk.getBytes();
  final prekeys = <int, String>{};
  for (final e in device.opks.entries) {
    prekeys[e.key] = base64Encode(await e.value.pk.getBytes());
  }
  final kemPrekeys = <int, String>{};
  final kemSigs = <int, String>{};
  for (final e in device.pqOpks.entries) {
    kemPrekeys[e.key] = base64Encode(
      serializeMlKem1024PublicKey(e.value.publicRaw),
    );
    kemSigs[e.key] = base64Encode(e.value.signature);
  }
  final pqIk = await pq.publicKey();
  final transcript = await device.identityTranscript(pqIk);
  final pqSig = await pq.sign(transcript);
  final ikSig = await device.sign(transcript);
  return Omemo2Bundle(
    deviceId: device.id,
    jid: device.jid,
    spk: base64Encode(spkRaw),
    spkId: device.spkId,
    spkSignature: base64Encode(device.spkSignature),
    ik: base64Encode(ikRaw),
    prekeys: prekeys,
    kemSpkId: device.pqSpkId,
    kemSpk: base64Encode(serializeMlKem1024PublicKey(device.pqSpk)),
    kemSpkSignature: base64Encode(device.pqSpkSignature),
    kemPrekeys: kemPrekeys,
    kemPrekeySignatures: kemSigs,
    pqIk: base64Encode(pqIk),
    pqSig: base64Encode(pqSig),
    ikSig: base64Encode(ikSig),
  );
}

void main() {
  setUpAll(() async {
    await omemo2EnsureLibSignal();
  });

  test(
    'ResonChat wire path bidirectional (pqcrypto id) + libsignal opens pq-ik',
    () async {
      final alice = await Omemo2Device.generate(
        'alice@example.org',
        opkCount: 2,
        pqOpkCount: 2,
        deviceId: 1001,
      );
      final bob = await Omemo2Device.generate(
        'bob@example.org',
        opkCount: 2,
        pqOpkCount: 2,
        deviceId: 2002,
      );

      final (aPk, aSk) = MlDsa.generateKeyPair(DilithiumParams.mlDsa87);
      final (bPk, bSk) = MlDsa.generateKeyPair(DilithiumParams.mlDsa87);
      final alicePq = _MemPq(aPk, aSk);
      final bobPq = _MemPq(bPk, bSk);

      final alicePub = await _publish(alice, alicePq);
      final bobPub = await _publish(bob, bobPq);

      // monocles libsignal accepts ResonChat-published <pq-ik>.
      expect(
        ls.PqIdentityKey.deserialize(bytes: base64Decode(alicePub.pqIk))
            .serialize(),
        base64Decode(alicePub.pqIk),
      );
      expect(
        ls.PqIdentityKey.deserialize(bytes: base64Decode(bobPub.pqIk))
            .serialize(),
        base64Decode(bobPub.pqIk),
      );

      final alicePeer = await DualTrackManager.deviceFromBundle(
        Omemo2Bundle.fromXml(
          bobPub.toXml(),
          jidOfBundle: bob.jid,
          deviceId: bob.id,
        ),
      );
      final bobPeer = await DualTrackManager.deviceFromBundle(
        Omemo2Bundle.fromXml(
          alicePub.toXml(),
          jidOfBundle: alice.jid,
          deviceId: alice.id,
        ),
      );
      expect(alicePeer, isNotNull);
      expect(bobPeer, isNotNull);

      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      final aliceDb = AppDatabase(NativeDatabase.memory());
      final bobDb = AppDatabase(NativeDatabase.memory());
      addTearDown(aliceDb.close);
      addTearDown(bobDb.close);

      final aliceLayer = PqMessageLayer(
        ownDevice: alice,
        sessions: PqSessionManager(),
        pqIdentity: alicePq,
        pins: Omemo2PqPinStore(aliceDb),
      );
      final bobLayer = PqMessageLayer(
        ownDevice: bob,
        sessions: PqSessionManager(),
        pqIdentity: bobPq,
        pins: Omemo2PqPinStore(bobDb),
      );

      final a2b = await aliceLayer.encrypt(
        plaintext: 'hello from ResonChat',
        recipients: [alicePeer!],
      );
      expect(a2b, isNotNull);
      expect(a2b!.stanza.pqAuth, isNotNull);
      expect(a2b.stanza.keys.single.kex, isTrue);
      expect(
        await bobLayer.decrypt(
          PqEncryptedMessage.fromXml(a2b.stanza.toXml()),
          senderBareJid: alice.jid,
        ),
        'hello from ResonChat',
      );

      final b2a = await bobLayer.encrypt(
        plaintext: 'hello back',
        recipients: [bobPeer!],
      );
      expect(b2a, isNotNull, reason: 'reply encrypt must succeed');
      // Responder's first reply is usually not kex; pq-auth only when kex.
      expect(
        await aliceLayer.decrypt(
          PqEncryptedMessage.fromXml(b2a!.stanza.toXml()),
          senderBareJid: bob.jid,
        ),
        'hello back',
      );

      final a2b2 = await aliceLayer.encrypt(
        plaintext: 'follow-up',
        recipients: [alicePeer],
      );
      expect(
        await bobLayer.decrypt(
          PqEncryptedMessage.fromXml(a2b2!.stanza.toXml()),
          senderBareJid: alice.jid,
        ),
        'follow-up',
      );
    },
  );

  test(
    'libsignal PqIdentityKeyPair signs a publish monocles would verify',
    () async {
      final device = await Omemo2Device.generate(
        'm@example.org',
        opkCount: 1,
        pqOpkCount: 1,
      );
      final pair = ls.PqIdentityKeyPair.generate();
      final pq = _LibsignalPq(pair);
      final published = await _publish(device, pq);
      expect(await verifyOmemo2Bundle(published), isTrue);

      // ResonChat pqcrypto verifies the same <pq-sig>.
      final transcript = await device.identityTranscript(
        Uint8List.fromList(base64Decode(published.pqIk)),
      );
      expect(
        MlDsa.verify(
          Uint8List.fromList(base64Decode(published.pqIk)),
          transcript,
          Uint8List.fromList(base64Decode(published.pqSig)),
          DilithiumParams.mlDsa87,
          ctx: Uint8List.fromList(utf8.encode(omemo2PqIdContext)),
        ),
        isTrue,
      );
    },
  );

  test(
    'Omemo2Manager SPQR KEX: PreKey ciphertext carries kyber + pq_ratchet',
    () async {
      final aliceDev = await Omemo2Device.generate(
        'a@example.org',
        opkCount: 1,
        pqOpkCount: 1,
      );
      final bobDev = await Omemo2Device.generate(
        'b@example.org',
        opkCount: 1,
        pqOpkCount: 1,
      );

      Future<Omemo2PreKeyBundle> signed(Omemo2Device d) async {
        final pq = ls.PqIdentityKeyPair.generate();
        final pqPub = Uint8List.fromList(pq.publicKey().serialize());
        final transcript = await d.identityTranscript(pqPub);
        final pqSig = Uint8List.fromList(
          pq.sign(message: transcript).serialize(),
        );
        final ikSig = await d.sign(transcript);
        final opk = d.opks.entries.first;
        final spkRaw = await d.spk.pk.getBytes();
        final opkRaw = await opk.value.pk.getBytes();
        return Omemo2PreKeyBundle.fromParts(
          jid: d.jid,
          deviceId: d.id,
          identityPublicTagged: await d.identityPublicSerialized(),
          signedPreKeyId: d.spkId,
          signedPreKeyPublicTagged: Uint8List.fromList([0x05, ...spkRaw]),
          signedPreKeySignature: d.spkSignature,
          preKeyId: opk.key,
          preKeyPublicTagged: Uint8List.fromList([0x05, ...opkRaw]),
          kyberSignedPreKeyId: d.pqSpkId,
          kyberSignedPreKeyPublicRaw: d.pqSpk,
          kyberSignedPreKeySignature: d.pqSpkSignature,
          kyberOneTime: {
            for (final e in d.pqOpks.entries)
              e.key: (
                publicRaw: e.value.publicRaw,
                signature: e.value.signature,
              ),
          },
          pqIdentityKey: pqPub,
          pqSignature: pqSig,
          ikSignature: ikSig,
        );
      }

      final aliceBundle = await signed(aliceDev);
      final bobBundle = await signed(bobDev);
      Future<Omemo2PreKeyBundle?> of(String jid, int id) async {
        if (jid == bobDev.jid && id == bobDev.id) return bobBundle;
        if (jid == aliceDev.jid && id == aliceDev.id) return aliceBundle;
        return null;
      }

      final alice = Omemo2Manager(
        aliceDev,
        fetchDeviceList: (jid) async =>
            jid == bobDev.jid ? [bobDev.id] : [aliceDev.id],
        fetchBundle: of,
      );
      final bob = Omemo2Manager(
        bobDev,
        fetchDeviceList: (jid) async =>
            jid == aliceDev.jid ? [aliceDev.id] : [bobDev.id],
        fetchBundle: of,
      );
      await alice.onDeviceListUpdate(bobDev.jid, [bobDev.id]);
      await bob.onDeviceListUpdate(aliceDev.jid, [aliceDev.id]);

      final enc = await alice.onOutgoingStanza(
        Omemo2OutgoingStanza(
          recipientJids: [bobDev.jid],
          payload: utf8.encode('spqr-kex'),
        ),
      );
      expect(enc.canSend, isTrue);
      final key = enc.encryptedKeys[bobDev.jid]!.single;
      expect(key.kex, isTrue);

      final preKey = ls.PreKeySignalMessage.deserialize(
        data: Uint8List.fromList(key.data),
      );
      expect(preKey.message().pqRatchet(), isNotNull);
      expect(preKey.kyberCiphertext(), isNotNull);

      final dec = await bob.onIncomingStanza(
        Omemo2IncomingStanza(
          bareSenderJid: aliceDev.jid,
          senderDeviceId: aliceDev.id,
          recipientBareJid: bobDev.jid,
          keys: [key],
          payload: enc.ciphertext,
          commit: enc.commit,
        ),
      );
      expect(dec.error, isNull);
      expect(dec.payload, 'spqr-kex');
    },
  );
}
