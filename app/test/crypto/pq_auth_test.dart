// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// `<pq-auth>` parse / pin-if-absent / handshake refuse.

import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hex/hex.dart';
import 'package:omemo_dart/omemo_dart_omemo2.dart';
import 'package:pqcrypto/pqcrypto.dart';
import 'package:xml/xml.dart';

import 'package:resonchat/crypto/omemo2/message_codec.dart';
import 'package:resonchat/crypto/omemo2/pq_auth.dart';
import 'package:resonchat/crypto/omemo2/pq_message_layer.dart';
import 'package:resonchat/crypto/omemo2/pq_session.dart';
import 'package:resonchat/persistence/database.dart';
import 'package:resonchat/persistence/omemo2_pq_pin_store.dart';
import 'package:resonchat/persistence/pq_identity_store.dart';

class _MemPqIdentity implements PqIdentityStore {
  _MemPqIdentity(this.pk, this.sk);

  final Uint8List pk;
  final Uint8List sk;

  @override
  String get accountId => 'test';

  @override
  Future<Uint8List> publicKey() async => pk;

  @override
  Future<(Uint8List, Uint8List)> keyPair() async => (pk, sk);

  @override
  Future<Uint8List> sign(Uint8List message) async {
    return MlDsa.sign(
      sk,
      message,
      DilithiumParams.mlDsa87,
      ctx: Uint8List.fromList(utf8.encode(omemo2PqIdContext)),
    );
  }

  @override
  Future<void> clear() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUpAll(() async {
    await omemo2EnsureLibSignal();
  });

  test('parsePqAuth rejects wrong type / wrong length', () {
    expect(parsePqAuth(null), isNull);

    final wrongType = XmlDocument.parse(
      '<pq-auth><pq-ik type="ML-DSA-65">YQ==</pq-ik>'
      '<pq-sig>YQ==</pq-sig><ik-sig>YQ==</ik-sig></pq-auth>',
    ).rootElement;
    expect(parsePqAuth(wrongType), isNull);

    final short = XmlDocument.parse(
      '<pq-auth><pq-ik type="ML-DSA-87">${base64Encode([1, 2])}</pq-ik>'
      '<pq-sig>${base64Encode(List.filled(4627, 0))}</pq-sig>'
      '<ik-sig>${base64Encode(List.filled(64, 0))}</ik-sig></pq-auth>',
    ).rootElement;
    expect(parsePqAuth(short), isNull);
  });

  test('pinIfAbsent never overwrites an existing pin', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final pins = Omemo2PqPinStore(db);
    final a = Uint8List.fromList(List.filled(2592, 0x11));
    final b = Uint8List.fromList(List.filled(2592, 0x22));
    final first = await pins.pinIfAbsent('bob@example.org', '05aabb', a);
    expect(first, a);
    final second = await pins.pinIfAbsent('bob@example.org', '05aabb', b);
    expect(second, a);
    expect(await pins.pinnedPqIdentity('bob@example.org', '05aabb'), a);
  });

  test('encrypt attaches pq-auth; decrypt pins and opens', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final pins = Omemo2PqPinStore(db);

    final alice = await Omemo2Device.generate(
      'alice@example.org',
      opkCount: 2,
      pqOpkCount: 1,
      deviceId: 111,
    );
    final bob = await Omemo2Device.generate(
      'bob@example.org',
      opkCount: 2,
      pqOpkCount: 1,
      deviceId: 222,
    );

    final (alicePk, aliceSk) = MlDsa.generateKeyPair(DilithiumParams.mlDsa87);
    final alicePq = _MemPqIdentity(alicePk, aliceSk);

    // Publish-shaped peer: attach bob's hybrid identity onto a device for Alice.
    final (bobPk, bobSk) = MlDsa.generateKeyPair(DilithiumParams.mlDsa87);
    final bobTranscript = await bob.identityTranscript(bobPk);
    final bobPqSig = MlDsa.sign(
      bobSk,
      bobTranscript,
      DilithiumParams.mlDsa87,
      ctx: Uint8List.fromList(utf8.encode(omemo2PqIdContext)),
    );
    final bobIkSig = await bob.sign(bobTranscript);
    final bobPeer = Omemo2Device(
      jid: bob.jid,
      id: bob.id,
      ikEd: bob.ikEd,
      ikDh: bob.ikDh,
      spk: bob.spk,
      spkId: bob.spkId,
      spkSignature: bob.spkSignature,
      pqSpk: bob.pqSpk,
      pqSpkSecret: Uint8List(0),
      pqSpkId: bob.pqSpkId,
      pqSpkSignature: bob.pqSpkSignature,
      opks: bob.opks,
      pqOpks: {
        for (final e in bob.pqOpks.entries)
          e.key: Omemo2KyberPreKey(
            publicRaw: e.value.publicRaw,
            secretRaw: Uint8List(omemo2MlKemSecretKeyLength),
            signature: e.value.signature,
          ),
      },
      peerPqIdentityKey: bobPk,
      peerPqSignature: bobPqSig,
      peerIkSignature: bobIkSig,
    );

    final aliceLayer = PqMessageLayer(
      ownDevice: alice,
      sessions: PqSessionManager(),
      pqIdentity: alicePq,
      pins: pins,
    );
    final outgoing = await aliceLayer.encrypt(
      plaintext: 'hello pq-auth',
      recipients: [bobPeer],
    );
    expect(outgoing, isNotNull);
    expect(outgoing!.stanza.pqAuth, isNotNull);
    expect(outgoing.stanza.hasKex, isTrue);
    final xml = outgoing.stanza.toXml().toXmlString();
    expect(xml, contains('<pq-auth'));
    expect(xml, contains('<pq-ik'));

    // Bob receives: his own live device + pin store.
    final bobLayer = PqMessageLayer(
      ownDevice: bob,
      sessions: PqSessionManager(),
      pqIdentity: _MemPqIdentity(bobPk, bobSk),
      pins: pins,
    );
    final onWire = PqEncryptedMessage.fromXml(outgoing.stanza.toXml());
    final clear = await bobLayer.decrypt(onWire, senderBareJid: alice.jid);
    expect(clear, 'hello pq-auth');

    final aliceIk = await alice.identityPublicSerialized();
    final pinned = await pins.pinnedPqIdentity(alice.jid, HEX.encode(aliceIk));
    expect(pinned, alicePk);
  });

  test('decrypt refuses kex without pq-auth', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final pins = Omemo2PqPinStore(db);

    final alice = await Omemo2Device.generate(
      'alice@example.org',
      opkCount: 2,
      pqOpkCount: 1,
      deviceId: 111,
    );
    final bob = await Omemo2Device.generate(
      'bob@example.org',
      opkCount: 2,
      pqOpkCount: 1,
      deviceId: 222,
    );
    final (alicePk, aliceSk) = MlDsa.generateKeyPair(DilithiumParams.mlDsa87);
    final (bobPk, bobSk) = MlDsa.generateKeyPair(DilithiumParams.mlDsa87);
    final bobTranscript = await bob.identityTranscript(bobPk);
    final bobPeer = Omemo2Device(
      jid: bob.jid,
      id: bob.id,
      ikEd: bob.ikEd,
      ikDh: bob.ikDh,
      spk: bob.spk,
      spkId: bob.spkId,
      spkSignature: bob.spkSignature,
      pqSpk: bob.pqSpk,
      pqSpkSecret: Uint8List(0),
      pqSpkId: bob.pqSpkId,
      pqSpkSignature: bob.pqSpkSignature,
      opks: bob.opks,
      pqOpks: {
        for (final e in bob.pqOpks.entries)
          e.key: Omemo2KyberPreKey(
            publicRaw: e.value.publicRaw,
            secretRaw: Uint8List(omemo2MlKemSecretKeyLength),
            signature: e.value.signature,
          ),
      },
      peerPqIdentityKey: bobPk,
      peerPqSignature: MlDsa.sign(
        bobSk,
        bobTranscript,
        DilithiumParams.mlDsa87,
        ctx: Uint8List.fromList(utf8.encode(omemo2PqIdContext)),
      ),
      peerIkSignature: await bob.sign(bobTranscript),
    );

    final aliceLayer = PqMessageLayer(
      ownDevice: alice,
      sessions: PqSessionManager(),
      pqIdentity: _MemPqIdentity(alicePk, aliceSk),
      pins: Omemo2PqPinStore(AppDatabase(NativeDatabase.memory())),
    );
    final outgoing = await aliceLayer.encrypt(
      plaintext: 'x',
      recipients: [bobPeer],
    );
    expect(outgoing, isNotNull);
    // Strip <pq-auth> as a pre-0.0.13 sender would.
    final stripped = PqEncryptedMessage(
      senderDeviceId: outgoing!.stanza.senderDeviceId,
      recipients: outgoing.stanza.recipients,
      payload: outgoing.stanza.payload,
      commit: outgoing.stanza.commit,
    );
    expect(stripped.hasKex, isTrue);
    expect(stripped.pqAuth, isNull);

    final bobLayer = PqMessageLayer(
      ownDevice: bob,
      sessions: PqSessionManager(),
      pins: pins,
    );
    expect(
      () => bobLayer.decrypt(stripped, senderBareJid: alice.jid),
      throwsA(
        isA<PqDecryptError>().having(
          (e) => e.reason,
          'reason',
          contains('pq-auth'),
        ),
      ),
    );
  });

  test('decrypt refuses conflicting pin', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final pins = Omemo2PqPinStore(db);

    final alice = await Omemo2Device.generate(
      'alice@example.org',
      opkCount: 2,
      pqOpkCount: 1,
      deviceId: 11,
    );
    final bob = await Omemo2Device.generate(
      'bob@example.org',
      opkCount: 2,
      pqOpkCount: 1,
      deviceId: 22,
    );
    final (alicePk, aliceSk) = MlDsa.generateKeyPair(DilithiumParams.mlDsa87);
    final (otherPk, _) = MlDsa.generateKeyPair(DilithiumParams.mlDsa87);
    final aliceIk = await alice.identityPublicSerialized();
    await pins.pinIfAbsent(alice.jid, HEX.encode(aliceIk), otherPk);

    final (bobPk, bobSk) = MlDsa.generateKeyPair(DilithiumParams.mlDsa87);
    final bobTranscript = await bob.identityTranscript(bobPk);
    final bobPeer = Omemo2Device(
      jid: bob.jid,
      id: bob.id,
      ikEd: bob.ikEd,
      ikDh: bob.ikDh,
      spk: bob.spk,
      spkId: bob.spkId,
      spkSignature: bob.spkSignature,
      pqSpk: bob.pqSpk,
      pqSpkSecret: Uint8List(0),
      pqSpkId: bob.pqSpkId,
      pqSpkSignature: bob.pqSpkSignature,
      opks: bob.opks,
      pqOpks: {
        for (final e in bob.pqOpks.entries)
          e.key: Omemo2KyberPreKey(
            publicRaw: e.value.publicRaw,
            secretRaw: Uint8List(omemo2MlKemSecretKeyLength),
            signature: e.value.signature,
          ),
      },
      peerPqIdentityKey: bobPk,
      peerPqSignature: MlDsa.sign(
        bobSk,
        bobTranscript,
        DilithiumParams.mlDsa87,
        ctx: Uint8List.fromList(utf8.encode(omemo2PqIdContext)),
      ),
      peerIkSignature: await bob.sign(bobTranscript),
    );

    final aliceLayer = PqMessageLayer(
      ownDevice: alice,
      sessions: PqSessionManager(),
      pqIdentity: _MemPqIdentity(alicePk, aliceSk),
      pins: Omemo2PqPinStore(AppDatabase(NativeDatabase.memory())),
    );
    final outgoing = await aliceLayer.encrypt(
      plaintext: 'x',
      recipients: [bobPeer],
    );
    expect(outgoing, isNotNull);

    final bobLayer = PqMessageLayer(
      ownDevice: bob,
      sessions: PqSessionManager(),
      pins: pins,
    );
    expect(
      () => bobLayer.decrypt(outgoing!.stanza, senderBareJid: alice.jid),
      throwsA(
        isA<PqDecryptError>().having(
          (e) => e.reason,
          'reason',
          contains('CHANGED'),
        ),
      ),
    );
  });
}
