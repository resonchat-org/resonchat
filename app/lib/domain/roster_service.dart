// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Roster and conference-bookmark mapping at the persistence boundary.

import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:moxxmpp/moxxmpp.dart' show ConferenceBookmark, XmppRosterItem;

import 'package:resonchat/persistence/database.dart';

/// Maps protocol roster/bookmark types onto [AppDatabase] SQL.
class RosterService {
  RosterService(this._db);

  final AppDatabase _db;

  static const _conferenceBookmarksMetaKey = 'conference_bookmarks';

  /// Applies one roster commit (fetch result or push) atomically.
  Future<void> commitRoster({
    required String? version,
    required List<String> removed,
    required List<XmppRosterItem> modified,
    required List<XmppRosterItem> added,
  }) async {
    final upserts = <RosterEntriesCompanion>[
      for (final item in [...modified, ...added])
        RosterEntriesCompanion(
          jid: Value(item.jid),
          name: Value(item.name ?? ''),
          subscription: Value(item.subscription),
          ask: Value(item.ask ?? ''),
          groups: Value(item.groups.join(',')),
        ),
    ];
    await _db.commitRosterRows(
      version: version,
      removed: removed,
      upserts: upserts,
    );
  }

  /// Last-known XEP-0402 / legacy conference bookmarks (cold-start UI cache).
  Future<List<ConferenceBookmark>> loadConferenceBookmarks() async {
    final raw = await _db.metaValue(_conferenceBookmarksMetaKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final out = <ConferenceBookmark>[];
      for (final item in decoded) {
        if (item is! Map) continue;
        final jid = item['jid'];
        if (jid is! String || jid.isEmpty) continue;
        out.add(
          ConferenceBookmark(
            jid: jid,
            name: item['name'] is String ? item['name'] as String : null,
            nick: item['nick'] is String ? item['nick'] as String : null,
            password: item['password'] is String
                ? item['password'] as String
                : null,
            autoJoin: item['autoJoin'] == true,
          ),
        );
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  Future<void> saveConferenceBookmarks(List<ConferenceBookmark> list) async {
    final payload = [
      for (final b in list)
        {
          'jid': b.jid,
          if (b.name != null && b.name!.isNotEmpty) 'name': b.name,
          if (b.nick != null && b.nick!.isNotEmpty) 'nick': b.nick,
          if (b.password != null && b.password!.isNotEmpty)
            'password': b.password,
          'autoJoin': b.autoJoin,
        },
    ];
    await _db.setMetaValue(_conferenceBookmarksMetaKey, jsonEncode(payload));
  }
}
