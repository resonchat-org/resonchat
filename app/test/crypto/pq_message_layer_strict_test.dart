// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Strict allow-list contract at the message layer (docs/11 §5.3).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:omemo_dart/omemo_dart_omemo2.dart';

import 'package:resonchat/crypto/omemo2/pq_message_layer.dart';
import 'package:resonchat/crypto/omemo2/pq_session.dart';

class _FakeSessions implements PqSessionManager {
  int outgoingCalls = 0;
  List<String>? recipientJids;
  Map<String, Set<int>>? recipientDeviceIds;

  @override
  Future<void> bindOwn(PqDevice own) async {}

  @override
  Future<void> setPeerAnnouncedDeviceIds(String jid, Iterable<int> ids) async {}

  @override
  Future<void> registerPeerBundle(PqDevice peer) async {}

  @override
  Future<Omemo2EncryptionResult> encryptOutgoing({
    required List<String> recipientJids,
    required List<int>? payload,
    Map<String, Set<int>>? recipientDeviceIds,
  }) async {
    outgoingCalls++;
    this.recipientJids = recipientJids;
    this.recipientDeviceIds = recipientDeviceIds;
    return Omemo2EncryptionResult(
      ciphertext: const [1, 2],
      commit: const [3, 4],
      encryptedKeys: {
        recipientJids.first: [
          Omemo2EncryptedKey(2, base64Encode(const [9, 9]), true),
        ],
      },
      deviceEncryptionErrors: const {},
      newSessions: const {},
      canSend: true,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName} is not used here');
}

void main() {
  late Omemo2Device own;
  late _FakeSessions sessions;
  late PqMessageLayer layer;

  setUp(() async {
    own = await Omemo2Device.generate(
      'me@example.org',
      opkCount: 1,
      pqOpkCount: 1,
    );
    sessions = _FakeSessions();
    layer = PqMessageLayer(ownDevice: own, sessions: sessions);
  });

  test('a requested JID without an allow-list entry is rejected', () async {
    final outgoing = await layer.encrypt(
      plaintext: 'secret',
      requestedJids: const ['bob@example.org'],
      recipientDeviceIds: const <String, Set<int>>{},
    );
    expect(outgoing, isNull);
    expect(sessions.outgoingCalls, 0);
  });

  test('an announced list missing a requested JID is rejected', () async {
    final outgoing = await layer.encrypt(
      plaintext: 'secret',
      requestedJids: const ['bob@example.org'],
      announcedDeviceIds: const <String, Set<int>>{},
      recipientDeviceIds: const {
        'bob@example.org': <int>{1},
      },
    );
    expect(outgoing, isNull);
    expect(sessions.outgoingCalls, 0);
  });

  test('an empty allow-list is not treated as a fallback', () async {
    final outgoing = await layer.encrypt(
      plaintext: 'secret',
      requestedJids: const ['bob@example.org'],
      announcedDeviceIds: const {
        'bob@example.org': <int>{1},
      },
      recipientDeviceIds: const {'bob@example.org': <int>{}},
    );
    expect(outgoing, isNull);
    expect(sessions.outgoingCalls, 0);
  });

  test('only non-empty allowed JIDs reach the vendor', () async {
    final outgoing = await layer.encrypt(
      plaintext: 'secret',
      requestedJids: const ['bob@example.org', 'carol@example.org'],
      announcedDeviceIds: const {
        'bob@example.org': <int>{1},
        'carol@example.org': <int>{2},
      },
      recipientDeviceIds: const {
        'bob@example.org': <int>{},
        'carol@example.org': <int>{2},
      },
    );

    expect(outgoing, isNotNull);
    expect(sessions.outgoingCalls, 1);
    expect(sessions.recipientJids, ['carol@example.org']);
    expect(sessions.recipientDeviceIds, {
      'bob@example.org': <int>{},
      'carol@example.org': <int>{2},
    });
    expect(outgoing!.stanza.keys.single.recipientDeviceId, 2);
  });
}
