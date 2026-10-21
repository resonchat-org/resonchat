// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Who has read a message in a private non-anonymous room.
//
// Conversations `DisplayedManager` only keeps a read-by marker when the room
// is members-only and non-anonymous, and only for occupants who have a real
// JID and rank at least member. The denominator of "everyone" is that same
// set, minus our own account.

import 'dart:convert';

import 'package:resonchat/xmpp/muc/muc.dart';

/// JSON array of bare real JIDs stored on [Message.readBy].
Set<String> decodeReadBy(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return {};
  try {
    final decoded = jsonDecode(trimmed);
    if (decoded is! List) return {};
    return {
      for (final item in decoded)
        if (item is String && item.trim().isNotEmpty) item.trim().toLowerCase(),
    };
  } on FormatException {
    return {};
  }
}

String encodeReadBy(Set<String> jids) => jsonEncode(jids.toList()..sort());

/// Members who count toward the read ring, split by [readJids].
///
/// [selfNick] and [selfBareJid] are dropped. Occupants without a real JID, or
/// below member affiliation, are not in either list.
({List<Occupant> read, List<Occupant> unread}) splitGroupReads({
  required List<Occupant> occupants,
  required String selfNick,
  required String? selfBareJid,
  required Set<String> readJids,
}) {
  final self = selfBareJid?.trim().toLowerCase() ?? '';
  final nick = selfNick.trim();
  final seen = <String>{};
  final read = <Occupant>[];
  final unread = <Occupant>[];
  for (final occupant in occupants) {
    if (!occupant.isMemberOrAbove) continue;
    final jid = occupant.realJid?.trim().toLowerCase() ?? '';
    if (jid.isEmpty || !jid.contains('@')) continue;
    if (nick.isNotEmpty && occupant.nick == nick) continue;
    if (self.isNotEmpty && jid == self) continue;
    if (!seen.add(jid)) continue;
    if (readJids.contains(jid)) {
      read.add(occupant);
    } else {
      unread.add(occupant);
    }
  }
  return (read: read, unread: unread);
}

/// 0 when nobody who counts has read, 1 when every one of them has.
double groupReadFraction({
  required List<Occupant> occupants,
  required String selfNick,
  required String? selfBareJid,
  required Set<String> readJids,
}) {
  final split = splitGroupReads(
    occupants: occupants,
    selfNick: selfNick,
    selfBareJid: selfBareJid,
    readJids: readJids,
  );
  final total = split.read.length + split.unread.length;
  if (total == 0) return 0;
  return split.read.length / total;
}
