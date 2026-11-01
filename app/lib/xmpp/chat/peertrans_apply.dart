// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Apply inbound peertrans: crypto gates, trust filter, candidate store, winner.

import 'package:resonchat/crypto/dual/track.dart';
import 'package:resonchat/persistence/database.dart';
import 'package:resonchat/xmpp/chat/peertrans.dart';
import 'package:resonchat/xmpp/inbound/inbound_message.dart';

/// Result of attempting to consume a peertrans stanza (no chat bubble).
enum PeerTransApplyResult {
  /// Handled as peertrans (merged, buffered, or rejected by policy).
  consumed,

  /// Not a peertrans stanza.
  notPeerTrans,
}

/// Whether the parent message's encryption class allows this peertrans.
bool peertransCryptoAllowsMerge({
  required String? parentEncMode,
  required Track? peertransTrack,
}) {
  final parent = EncModeToken.parse(parentEncMode ?? EncModeToken.none.wire);
  final parentTrack = parent.track;

  // A-track (legacy OMEMO) parents: never merge.
  if (parentTrack == Track.standard) return false;

  final child = peertransTrack ?? Track.none;

  if (parentTrack == Track.none) {
    return child == Track.none;
  }
  if (parentTrack == Track.pq) {
    return child == Track.pq;
  }
  return false;
}

/// Applies [data] from [msg] into [db] for [chatJid].
///
/// Returns [PeerTransApplyResult.consumed] when the stanza was peertrans
/// (caller must not insert a normal bubble).
Future<PeerTransApplyResult> applyInboundPeerTrans({
  required AppDatabase db,
  required String chatJid,
  required InboundMessage msg,
  required PeerTransData data,
  required bool adminsOnly,
  required String? senderAffiliation,
  required Future<Message?> Function(String parentId) findParent,
}) async {
  final supplementId = (msg.originId ?? msg.stanzaId ?? '').trim();
  if (supplementId.isEmpty) return PeerTransApplyResult.consumed;

  if (adminsOnly && !peertransSenderIsAdmin(senderAffiliation)) {
    return PeerTransApplyResult.consumed;
  }

  final sender = msg.type == 'groupchat' && msg.from.resource.isNotEmpty
      ? msg.from.resource
      : msg.from.toBare().toString();
  final stamp = msg.archiveTimestamp ?? DateTime.now();

  for (final body in data.bodies) {
    final parent = await findParent(data.parentId);
    if (parent == null) {
      // Buffer only plaintext peertrans; encrypted early-arrivals need the
      // parent present so the crypto class can be checked with EME/track.
      if ((msg.track ?? Track.none) == Track.none) {
        await db.upsertPendingPeerTrans(
          chatJid: chatJid,
          parentId: data.parentId,
          lang: body.lang,
          body: body.text,
          priority: data.priority,
          sender: sender,
          supplementId: supplementId,
          timestamp: stamp,
        );
      }
      continue;
    }

    if (!peertransCryptoAllowsMerge(
      parentEncMode: parent.encMode,
      peertransTrack: msg.track,
    )) {
      continue;
    }

    await _acceptCandidate(
      db: db,
      chatJid: chatJid,
      parentId: data.parentId,
      lang: body.lang,
      body: body.text,
      sourceLang: body.sourceLang ?? '',
      engine: body.engine ?? 'peertrans',
      priority: data.priority,
      sender: sender,
      supplementId: supplementId,
      timestamp: stamp,
    );
  }

  return PeerTransApplyResult.consumed;
}

/// XEP-0308 on a peertrans supplement: replace that sender's candidate.
Future<bool> applyPeerTransCorrection({
  required AppDatabase db,
  required String chatJid,
  required String supplementId,
  required String newBody,
  required int priority,
  required String lang,
  required DateTime timestamp,
  String sourceLang = '',
  String engine = 'peertrans',
}) async {
  final existing = await db.peerTransBySupplementId(chatJid, supplementId);
  if (existing == null) return false;

  await db.deletePeerTransCandidate(
    chatJid: chatJid,
    supplementId: supplementId,
  );
  await _acceptCandidate(
    db: db,
    chatJid: chatJid,
    parentId: existing.parentId,
    lang: lang.isNotEmpty ? lang : existing.lang,
    body: newBody,
    sourceLang: sourceLang,
    engine: engine,
    priority: priority,
    sender: existing.sender,
    supplementId: supplementId,
    timestamp: timestamp,
  );
  return true;
}

/// Flush buffered peertrans once [parentId] is stored.
///
/// Only plaintext parents accept flushed (plaintext) pending rows.
Future<void> flushPendingPeerTrans({
  required AppDatabase db,
  required String chatJid,
  required String parentId,
  required String parentEncMode,
}) async {
  final pending = await db.takePendingPeerTransForParent(
    chatJid: chatJid,
    parentId: parentId,
  );
  if (EncModeToken.parse(parentEncMode).track != Track.none) {
    // Pending rows are plaintext-only; drop against encrypted parents.
    return;
  }
  for (final row in pending) {
    await _acceptCandidate(
      db: db,
      chatJid: chatJid,
      parentId: row.parentId,
      lang: row.lang,
      body: row.body,
      sourceLang: '',
      engine: 'peertrans',
      priority: row.priority,
      sender: row.sender,
      supplementId: row.supplementId,
      timestamp: row.timestamp,
    );
  }
}

Future<void> _acceptCandidate({
  required AppDatabase db,
  required String chatJid,
  required String parentId,
  required String lang,
  required String body,
  required String sourceLang,
  required String engine,
  required int priority,
  required String sender,
  required String supplementId,
  required DateTime timestamp,
}) async {
  final prior = await db.peerTransCandidatesForSender(
    chatJid: chatJid,
    parentId: parentId,
    lang: lang,
    sender: sender,
  );
  // Same sender without 0308: ignore later (first wins). Correction deletes
  // then re-inserts the same supplementId.
  final other = prior.where((c) => c.supplementId != supplementId).toList();
  if (other.isNotEmpty) {
    final earliest = other.reduce(
      (a, b) => a.timestamp.isBefore(b.timestamp) ? a : b,
    );
    if (timestamp.isAfter(earliest.timestamp) ||
        (timestamp.isAtSameMomentAs(earliest.timestamp) &&
            supplementId.compareTo(earliest.supplementId) > 0)) {
      return;
    }
  }

  final all = await db.upsertPeerTransCandidate(
    chatJid: chatJid,
    parentId: parentId,
    lang: lang,
    body: body,
    priority: priority,
    sender: sender,
    supplementId: supplementId,
    timestamp: timestamp,
  );

  // Same-sender filter for ranking: only earliest per sender.
  final bySender = <String, PeerTransCandidate>{};
  for (final c in all) {
    final prev = bySender[c.sender];
    if (prev == null ||
        c.timestamp.isBefore(prev.timestamp) ||
        (c.timestamp.isAtSameMomentAs(prev.timestamp) &&
            c.supplementId.compareTo(prev.supplementId) < 0)) {
      bySender[c.sender] = c;
    }
  }
  final ranked = [
    for (final c in bySender.values)
      PeerTransRanked(
        priority: c.priority,
        sender: c.sender,
        supplementId: c.supplementId,
        timestamp: c.timestamp,
        body: c.body,
      ),
  ];
  final winner = selectPeerTransWinner(ranked);
  await db.applyPeerTransWinner(
    chatJid: chatJid,
    parentId: parentId,
    lang: lang,
    body: winner?.body,
    sourceLang: sourceLang,
    engine: engine.isEmpty ? 'peertrans' : engine,
    by: winner == null ? '' : peertransSourceLabel(winner.sender),
  );
}
