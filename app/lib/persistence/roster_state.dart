// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Roster persistence bridge: moxxmpp's RosterManager delegates all
// storage to a BaseRosterStateManager, which we back with drift so the
// contact list survives restarts (M1).

import 'package:moxxmpp/moxxmpp.dart';

import 'package:resonchat/domain/roster_service.dart';
import 'package:resonchat/persistence/database.dart';

class DriftRosterStateManager extends BaseRosterStateManager {
  DriftRosterStateManager(this._db) : _roster = RosterService(_db);

  final AppDatabase _db;
  final RosterService _roster;

  @override
  Future<RosterCacheLoadResult> loadRosterCache() async {
    final rows = await _db.allRosterEntries();
    return RosterCacheLoadResult(await _db.rosterVersion(), [
      for (final r in rows)
        XmppRosterItem(
          jid: r.jid,
          name: r.name.isEmpty ? null : r.name,
          subscription: r.subscription,
          ask: r.ask.isEmpty ? null : r.ask,
          groups: r.groups.isEmpty
              ? const []
              : (r.groups as List<dynamic>).cast<String>().toList(),
        ),
    ]);
  }

  @override
  Future<void> commitRoster(
    String? version,
    List<String> removed,
    List<XmppRosterItem> modified,
    List<XmppRosterItem> added,
  ) async {
    await _roster.commitRoster(
      version: version,
      removed: removed,
      modified: modified,
      added: added,
    );
  }
}
