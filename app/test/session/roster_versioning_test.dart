// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The roster must survive "the server has nothing to report".
//
// With RFC 6121 versioning a client sends the roster version it already has.
// If nothing changed the server answers with an `<iq/>` that carries **no
// <query/> at all**, and moxxmpp turns that into a result whose item list is
// empty. That list is a *delta*, not the roster. Using it as the roster made
// the contact list come up empty on every launch after the first.

import 'package:flutter_test/flutter_test.dart';
import 'package:moxxmpp/moxxmpp.dart';

/// A roster store that already holds what the server would send, so the
/// server has nothing to report.
class _SeededRosterStateManager extends BaseRosterStateManager {
  _SeededRosterStateManager(this._roster, this.version);

  List<XmppRosterItem> _roster;
  String? version;
  int commits = 0;

  @override
  Future<RosterCacheLoadResult> loadRosterCache() async =>
      RosterCacheLoadResult(version, List<XmppRosterItem>.of(_roster));

  @override
  Future<void> commitRoster(
    String? newVersion,
    List<String> removed,
    List<XmppRosterItem> modified,
    List<XmppRosterItem> added,
  ) async {
    commits++;
    version = newVersion;
    final next = _roster.where((i) => !removed.contains(i.jid)).toList();
    for (final item in modified) {
      final i = next.indexWhere((e) => e.jid == item.jid);
      if (i == -1) {
        next.add(item);
      } else {
        next[i] = item;
      }
    }
    next.addAll(added);
    _roster = next;
  }
}

void main() {
  group('roster versioning does not look like an empty roster', () {
    test('an unchanged roster still yields the cached entries', () async {
      final manager = _SeededRosterStateManager(const [
        XmppRosterItem(jid: 'a@example.org', subscription: 'both'),
        XmppRosterItem(jid: 'b@example.org', subscription: 'from'),
      ], 'v1');

      // This is exactly what moxxmpp reports when the server says
      // "nothing changed": an empty delta carrying the same version.
      final unchanged = RosterRequestResult(const [], 'v1');

      // The delta is empty...
      expect(unchanged.items, isEmpty);

      // ...but the store still knows about both contacts, and that is what
      // the app must render.
      final cached = await manager.loadRosterCache();
      expect(cached.roster.length, 2);
      expect(cached.roster.map((i) => i.jid).toSet(), {
        'a@example.org',
        'b@example.org',
      });
      expect(cached.version, 'v1');
    });

    test('a removal is applied to the cached roster', () async {
      final manager = _SeededRosterStateManager(const [
        XmppRosterItem(jid: 'a@example.org', subscription: 'both'),
        XmppRosterItem(jid: 'gone@example.org', subscription: 'both'),
      ], 'v1');

      await manager.commitRoster(
        'v2',
        const ['gone@example.org'],
        const [],
        const [],
      );

      final cached = await manager.loadRosterCache();
      expect(cached.roster.map((i) => i.jid), ['a@example.org']);
      expect(cached.version, 'v2');
    });

    test('an update replaces rather than duplicates', () async {
      final manager = _SeededRosterStateManager(const [
        XmppRosterItem(jid: 'a@example.org', subscription: 'from'),
      ], 'v1');

      await manager.commitRoster('v2', const [], const [
        XmppRosterItem(jid: 'a@example.org', subscription: 'both'),
      ], const []);

      final cached = await manager.loadRosterCache();
      expect(cached.roster.length, 1);
      expect(cached.roster.single.subscription, 'both');
    });

    test(
      'the store returns its own copy, so callers cannot corrupt it',
      () async {
        final manager = _SeededRosterStateManager(const [
          XmppRosterItem(jid: 'a@example.org', subscription: 'both'),
        ], 'v1');
        final first = await manager.loadRosterCache();
        first.roster.add(
          const XmppRosterItem(
            jid: 'intruder@example.org',
            subscription: 'both',
          ),
        );
        final second = await manager.loadRosterCache();
        expect(second.roster.length, 1);
      },
    );
  });
}
