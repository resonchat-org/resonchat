// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// CapabilityService caching. The important property is that a resolved
// answer is reused until something invalidates it, and that a *failed*
// resolution is not cached — otherwise a transient network error would
// pin the chat to "unencrypted" for the whole TTL.

import 'package:flutter_test/flutter_test.dart';
import 'package:moxxmpp/moxxmpp.dart';
import 'package:resonchat/xmpp/capabilities.dart';

/// Thrown by the fake tracks() so we can count resolution attempts.
class _Boom implements Exception {
  const _Boom();
}

void main() {
  late int resolves;

  setUp(() => resolves = 0);

  CapabilityService build({Duration ttl = const Duration(minutes: 5)}) =>
      CapabilityService(
        tracks: () {
          resolves++;
          throw const _Boom();
        },
        ourDeviceId: () async => 100,
        ttl: ttl,
      );

  test('a failed resolution is not cached', () async {
    final service = build();
    final jid = JID.fromString('bob@example.org');

    await expectLater(service.forChat(jid), throwsA(isA<_Boom>()));
    expect(resolves, 1);

    // A second attempt must retry rather than serve a poisoned entry.
    await expectLater(service.forChat(jid), throwsA(isA<_Boom>()));
    expect(
      resolves,
      2,
      reason: 'failures must not be cached',
    );
  });

  test('a zero TTL disables caching', () async {
    final service = build(ttl: Duration.zero);
    final jid = JID.fromString('bob@example.org');

    await expectLater(service.forChat(jid), throwsA(isA<_Boom>()));
    await expectLater(service.forChat(jid), throwsA(isA<_Boom>()));
    expect(resolves, 2);
  });

  test('concurrent lookups for one chat resolve only once', () async {
    final service = build();
    final jid = JID.fromString('bob@example.org');

    // Fire three lookups without awaiting between them: the in-flight
    // de-duplication should collapse them into a single resolution.
    final futures = [
      service.forChat(jid).catchError((Object _) => throw const _Boom()),
      service.forChat(jid).catchError((Object _) => throw const _Boom()),
      service.forChat(jid).catchError((Object _) => throw const _Boom()),
    ];
    await Future.wait(futures).catchError((Object _) => <ChatCapabilities>[]);

    expect(
      resolves,
      1,
      reason: 'concurrent lookups must share one in-flight resolution',
    );
  });

  test('invalidate and invalidateAll are safe on an empty cache', () {
    final service = build();
    expect(() => service.invalidate(JID.fromString('a@b')), returnsNormally);
    expect(
      () => service.invalidate(JID.fromString('a@b/phone')),
      returnsNormally,
    );
    expect(service.invalidateAll, returnsNormally);
  });
}