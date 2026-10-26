// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:moxxmpp/moxxmpp.dart';
import 'package:test/test.dart';

import 'package:resonchat/xmpp/roster/last_seen.dart';
import 'package:resonchat/xmpp/roster/presence_store.dart';

void main() {
  test('last seen is the latest idle only when every resource is idle', () {
    final store = PresenceStore();
    final earlier = DateTime.utc(2026, 1, 2, 3);
    final later = DateTime.utc(2026, 1, 2, 4);

    store.apply(
      PresenceData(
        from: JID.fromString('a@example.org/phone'),
        available: true,
      ),
      idleSince: earlier,
    );
    store.apply(
      PresenceData(
        from: JID.fromString('a@example.org/laptop'),
        available: true,
        show: PresenceShow.away,
      ),
    );
    expect(store.of('a@example.org')?.idleSince, isNull);

    store.apply(
      PresenceData(
        from: JID.fromString('a@example.org/laptop'),
        available: true,
        show: PresenceShow.away,
      ),
      idleSince: later,
    );
    expect(store.of('a@example.org')?.idleSince, later);

    store.apply(
      PresenceData(
        from: JID.fromString('a@example.org/laptop'),
        available: false,
      ),
    );
    expect(store.of('a@example.org')?.idleSince, earlier);
  });

  test('last seen clock drops the date when it is today', () {
    final now = DateTime(2026, 3, 4, 15, 30);
    expect(formatLastSeenWhen(DateTime(2026, 3, 4, 9, 5), now: now), '09:05');
    expect(
      formatLastSeenWhen(DateTime(2026, 3, 3, 9, 5), now: now),
      '2026-03-03 09:05',
    );
  });
}
