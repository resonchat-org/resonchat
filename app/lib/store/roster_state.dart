// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Roster persistence bridge: moxxmpp's RosterManager delegates all
// storage to a BaseRosterStateManager, which we back with drift so the
// contact list survives restarts (M1).

import 'package:moxxmpp/moxxmpp.dart';

import '../store/database.dart';

class DriftRosterStateManager extends BaseRosterStateManager {
  DriftRosterStateManager(this._db);

  final AppDatabase _db;

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
    await _db.commitRoster(
      version: version,
      removed: removed,
      modified: modified,
      added: added,
    );
  }
}
