// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:drift/native.dart';
import 'package:test/test.dart';
import 'package:resonchat/crypto/omemo/fingerprint_trust.dart';
import 'package:resonchat/store/database.dart';

void main() {
  late AppDatabase db;
  late FingerprintTrustStore store;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    store = FingerprintTrustStore(db);
  });

  tearDown(() => db.close());

  test('unseen fingerprints are trusted (BTBV)', () async {
    expect(
      await store.getTrust('alice@example.org', 'aabbcc'),
      FingerprintTrust.trusted,
    );
    expect(await store.mayEncryptTo('alice@example.org', 'aabbcc'), isTrue);
  });

  test('distrust is per fingerprint, not per contact', () async {
    await store.setTrust(
      'alice@example.org',
      'deadbeef',
      FingerprintTrust.untrusted,
    );
    expect(await store.mayEncryptTo('alice@example.org', 'deadbeef'), isFalse);
    expect(
      await store.mayEncryptTo('alice@example.org', 'cafebabe'),
      isTrue,
      reason: 'other fingerprints stay trusted',
    );
  });

  test('trust keys are scoped to the bare JID', () async {
    await store.setTrust(
      'alice@example.org',
      'samefp',
      FingerprintTrust.untrusted,
    );
    expect(
      await store.mayEncryptTo('bob@example.org', 'samefp'),
      isTrue,
      reason: 'same hex under another JID must not inherit distrust',
    );
  });

  test('rememberDevice seeds BTBV and caches device id', () async {
    await store.rememberDevice(
      jid: 'alice@example.org',
      deviceId: 42,
      fingerprint: 'AA BB CC',
      omemo2: false,
    );
    expect(
      await store.fingerprintOfDevice('alice@example.org', 42, omemo2: false),
      'aabbcc',
    );
    expect(
      await store.getTrust('alice@example.org', 'aabbcc'),
      FingerprintTrust.trusted,
    );
    final rows = await store.identitiesFor('alice@example.org');
    expect(rows, hasLength(1));
    expect(rows.single.active, isTrue);
  });

  test('normalize strips whitespace and case', () {
    expect(FingerprintTrustStore.normalize('Aa Bb'), 'aabb');
  });

  test('syncAnnouncedDevices marks missing ids inactive', () async {
    await store.rememberDevice(
      jid: 'alice@example.org',
      deviceId: 1,
      fingerprint: 'aa',
      omemo2: false,
    );
    await store.rememberDevice(
      jid: 'alice@example.org',
      deviceId: 2,
      fingerprint: 'bb',
      omemo2: false,
    );
    await store.syncAnnouncedDevices(
      jid: 'alice@example.org',
      announcedIds: const [1],
      omemo2: false,
    );
    final rows = await store.identitiesFor('alice@example.org', omemo2: false);
    expect(rows.firstWhere((r) => r.deviceId == 1).active, isTrue);
    expect(rows.firstWhere((r) => r.deviceId == 2).active, isFalse);
    expect(
      await store.mayEncryptToActive('alice@example.org', 'bb'),
      isFalse,
      reason: 'inactive devices are skipped on encrypt',
    );
    expect(await store.mayEncryptToActive('alice@example.org', 'aa'), isTrue);
  });

  test('sync does not cross stacks', () async {
    await store.rememberDevice(
      jid: 'alice@example.org',
      deviceId: 7,
      fingerprint: 'classic',
      omemo2: false,
    );
    await store.rememberDevice(
      jid: 'alice@example.org',
      deviceId: 7,
      fingerprint: 'hybriddeadbeef',
      omemo2: true,
    );
    await store.syncAnnouncedDevices(
      jid: 'alice@example.org',
      announcedIds: const [],
      omemo2: false,
    );
    final classic = await store.identitiesFor(
      'alice@example.org',
      omemo2: false,
    );
    final pq = await store.identitiesFor('alice@example.org', omemo2: true);
    expect(classic.single.active, isFalse);
    expect(pq.single.active, isTrue);
  });

  test('reactivating stamps lastActivation only when was inactive', () async {
    await store.rememberDevice(
      jid: 'alice@example.org',
      deviceId: 3,
      fingerprint: 'cc',
      omemo2: false,
    );
    final first = (await store.identitiesFor('alice@example.org')).single;
    await store.syncAnnouncedDevices(
      jid: 'alice@example.org',
      announcedIds: const [],
      omemo2: false,
    );
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await store.syncAnnouncedDevices(
      jid: 'alice@example.org',
      announcedIds: const [3],
      omemo2: false,
    );
    final again = (await store.identitiesFor('alice@example.org')).single;
    expect(again.active, isTrue);
    expect(again.lastActivation, greaterThan(first.lastActivation));
  });

  test('migrates legacy Meta fp_trust / fp_dev keys', () async {
    await db.setMetaValue('fp_trust:alice@example.org:aabb', 'untrusted');
    await db.setMetaValue('fp_dev:ax:alice@example.org:9', 'aabb');
    await db.setMetaValue('fp_dev:pq:alice@example.org:9', 'ccddee');

    // Trigger migration via any read.
    expect(
      await store.getTrust('alice@example.org', 'aabb'),
      FingerprintTrust.untrusted,
    );
    expect(
      await store.fingerprintOfDevice('alice@example.org', 9, omemo2: false),
      'aabb',
    );
    expect(
      await store.fingerprintOfDevice('alice@example.org', 9, omemo2: true),
      'ccddee',
    );
    expect(await db.metaValue('fp_store_v2'), '1');
    expect(await db.metaEntriesWithPrefix('fp_trust:'), isEmpty);
    expect(await db.metaEntriesWithPrefix('fp_dev:'), isEmpty);
  });
}
