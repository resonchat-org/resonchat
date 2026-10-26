// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Aggregates RFC 6121 presence per bare JID across resources.
//
// Like Gajim BareContact: keep each resource's show/priority, drop a resource
// on unavailable, and expose the "best" show (highest PresenceShow.rank, then
// priority) for UI dots.

import 'package:moxxmpp/moxxmpp.dart';

/// One contact's aggregated availability for the UI.
class ContactPresence {
  const ContactPresence({required this.show, this.status, this.idleSince});

  final PresenceShow show;
  final String? status;

  /// Latest XEP-0319 idle time when every resource is idle. Null when any
  /// resource is active (Gajim [BareContact.idle_datetime]).
  final DateTime? idleSince;

  bool get isAvailable => true;
}

class _ResourcePresence {
  _ResourcePresence({
    required this.show,
    required this.priority,
    this.status,
    this.idleSince,
  });

  PresenceShow show;
  int priority;
  String? status;
  DateTime? idleSince;
}

/// Live presence map for one XMPP session.
class PresenceStore {
  final Map<String, Map<String, _ResourcePresence>> _byBare = {};

  /// Aggregated show for [bareJid], or `null` when offline / unknown.
  ContactPresence? of(String bareJid) {
    final resources = _byBare[bareJid.toLowerCase()];
    if (resources == null || resources.isEmpty) return null;

    _ResourcePresence? best;
    DateTime? idle;
    var everyResourceIdle = true;
    for (final r in resources.values) {
      if (r.idleSince == null) {
        everyResourceIdle = false;
      } else if (idle == null || r.idleSince!.isAfter(idle)) {
        idle = r.idleSince;
      }
      if (best == null) {
        best = r;
        continue;
      }
      if (r.show.rank > best.show.rank ||
          (r.show.rank == best.show.rank && r.priority > best.priority)) {
        best = r;
      }
    }
    if (best == null) return null;
    return ContactPresence(
      show: best.show,
      status: best.status,
      idleSince: everyResourceIdle ? idle : null,
    );
  }

  /// Applies an inbound presence stanza.
  ///
  /// [idleSince] is XEP-0319 data from [IdleData], not part of RFC 6121.
  void apply(PresenceData data, {DateTime? idleSince}) {
    final bare = data.from.toBare().toString().toLowerCase();
    final resource = data.from.resource;

    if (!data.available) {
      if (resource.isEmpty) {
        // Bare unavailable: all resources of this contact went offline.
        _byBare.remove(bare);
      } else {
        final map = _byBare[bare];
        if (map == null) return;
        map.remove(resource);
        if (map.isEmpty) _byBare.remove(bare);
      }
      return;
    }

    final key = resource.isEmpty ? '' : resource;
    final map = _byBare.putIfAbsent(bare, () => {});
    map[key] = _ResourcePresence(
      show: data.show,
      priority: data.priority,
      status: data.status,
      idleSince: idleSince,
    );
  }

  /// Clears all cached presence (disconnect / new session).
  void clear() => _byBare.clear();
}
