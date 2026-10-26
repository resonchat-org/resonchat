// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Which id Conversations stores as `serverMsgId` for a group message.
//
// A MUC archive query's `<result id='…'/>` is that id. A live reflection
// contributes `<stanza-id by='room'/>` only when the room advertises
// `urn:xmpp:sid:0` (StanzaIdManager). An occupant can put a stanza-id on
// their own message; without the feature it is not the room's id.

import 'package:moxxmpp/moxxmpp.dart' show StanzaId;

/// True when a groupchat arrived on the account archive rather than the room's.
///
/// Conversations drops those (`received group chat message on regular MAM
/// request`). The account result id is not the room's stanza-id.
bool groupchatOnAccountArchive({
  required String archiveBare,
  required String roomBare,
}) {
  return archiveBare.trim().toLowerCase() != roomBare.trim().toLowerCase();
}

/// Room stanza-id for one groupchat stanza, or null when none is trustworthy.
///
/// [mucArchive] means the wrapper came from the room's own MAM. [archiveResultId]
/// is `<result id='…'/>`. When that is missing, [stanzaIds] is consulted only
/// if [trustStanzaId] (the room's disco includes `urn:xmpp:sid:0`).
String? roomServerMessageId({
  required bool mucArchive,
  required String? archiveResultId,
  required bool trustStanzaId,
  required List<StanzaId> stanzaIds,
  required String roomBare,
}) {
  if (mucArchive) {
    final id = archiveResultId?.trim() ?? '';
    if (id.isNotEmpty) return id;
  }
  if (!trustStanzaId) return null;
  final room = roomBare.trim().toLowerCase();
  if (room.isEmpty) return null;
  for (final stanza in stanzaIds) {
    final by = stanza.by.toBare().toString().toLowerCase();
    if (by == room && stanza.id.isNotEmpty) return stanza.id;
  }
  return null;
}
