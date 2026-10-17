// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Gajim `format_last_seen`: the XEP-0319 idle timestamp, shown only while the
// contact is still online. Nothing is written to the database.

import 'package:moxxmpp/moxxmpp.dart' show PresenceShow;

import '../l10n/l10n.dart';

/// Clock (and date, when not today) for [idle].
String formatLastSeenWhen(DateTime idle, {DateTime? now}) {
  final local = idle.toLocal();
  final n = (now ?? DateTime.now()).toLocal();
  final hm =
      '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
  final sameDay =
      local.year == n.year && local.month == n.month && local.day == n.day;
  if (sameDay) return hm;
  final date =
      '${local.year.toString().padLeft(4, '0')}-'
      '${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')}';
  return '$date $hm';
}

/// "Last seen: …", or null when [idleSince] is absent.
String? lastSeenLine(AppLocalizations l10n, DateTime? idleSince) {
  if (idleSince == null) return null;
  return l10n.lastSeen(formatLastSeenWhen(idleSince));
}

String presenceLabel(AppLocalizations l10n, PresenceShow? show) {
  return switch (show) {
    null => l10n.presenceOffline,
    PresenceShow.online => l10n.presenceOnline,
    PresenceShow.chat => l10n.presenceChat,
    PresenceShow.away => l10n.presenceAway,
    PresenceShow.xa => l10n.presenceXa,
    PresenceShow.dnd => l10n.presenceDnd,
  };
}
