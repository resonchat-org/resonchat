// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Message domain rules: inbound store, retraction, correction, pending merge.

import 'package:drift/drift.dart' show Value;

import 'package:resonchat/crypto/dual/fingerprint_trust.dart';
import 'package:resonchat/crypto/dual/track.dart';
import 'package:resonchat/persistence/database.dart';
import 'package:resonchat/persistence/prefs_database.dart';
import 'package:resonchat/xmpp/inbound/inbound_message.dart';
import 'package:resonchat/xmpp/inbound/reaction_update.dart';
import 'package:resonchat/xmpp/message_expiry.dart';
import 'package:resonchat/xmpp/message_send_status.dart';
import 'package:resonchat/xmpp/notify_policy.dart';

/// Domain rules for chat messages. Persistence stays on [AppDatabase].
class MessagesService {
  MessagesService(this._db);

  final AppDatabase _db;

  AppDatabase get db => _db;

  /// Marks the message addressed by [targetId] as retracted for everyone.
  ///
  /// Returns false when no such message is held, which is not an error: a
  /// retraction for a message that arrived out of order, or for one we never
  /// had, has to be a no-op rather than a failure.
  Future<bool> markRetracted(
    String targetId, {
    DateTime? at,
    String? by,
    String? reason,
  }) async {
    if (targetId.isEmpty) return false;
    // Never un-retract: a second retraction for the same message is a replay,
    // and honouring it would flip the marker back off.
    final stamp = at ?? DateTime.now();
    final nick = (by != null && by.isNotEmpty) ? by : null;
    final why = reason?.trim();
    final text = (why != null && why.isNotEmpty) ? why : null;
    final mark = MessagesCompanion(
      retracted: const Value(true),
      retractedAt: Value(stamp),
      retractedBy: nick != null ? Value(nick) : const Value.absent(),
      retractedReason: text != null ? Value(text) : const Value.absent(),
    );
    final byMessageId = await _db.markMessageRetractedByStanzaId(
      targetId,
      mark,
    );
    if (byMessageId > 0) return true;
    final byRoomId = await _db.markMessageRetractedByRoomStanzaId(
      targetId,
      mark,
    );
    if (byRoomId > 0) return true;

    // A plain retract can land before the moderation notice. Fill the
    // moderator and the reason without moving the timestamp or replacing a
    // nick we already have.
    var filled = false;
    if (nick != null) {
      if (await _db.fillRetractedByIfEmpty(targetId, nick) > 0) filled = true;
    }
    if (text != null) {
      if (await _db.fillRetractedReasonIfEmpty(targetId, text) > 0) {
        filled = true;
      }
    }
    return filled;
  }

  /// True when [chatJid] holds a message addressed by [targetId].
  Future<bool> messageAddressedBy(String chatJid, String targetId) =>
      _db.messageAddressedBy(chatJid, targetId);

  /// Applies a correction (XEP-0308) to the message addressed by [targetId],
  /// holding it when the original was never seen.
  Future<void> applyCorrection({
    required String chatJid,
    required String targetId,
    required String body,
    required String encMode,
  }) async {
    if (targetId.isEmpty) return;
    final now = DateTime.now();
    final updated = await _db.updateMessageBodyClearingRetract(
      targetId: targetId,
      body: body,
      editedAt: now,
    );
    if (updated > 0) {
      await _db.upsertChat(chatJid);
      return;
    }
    await _db.upsertPendingCorrection(
      targetId: targetId,
      body: body,
      encMode: encMode,
      correctedAt: now,
    );
  }

  /// Stores one reaction broadcast, replacing that reactor's previous set.
  Future<void> storeReaction(ReactionUpdate update) {
    return _db.setReactions(
      targetId: update.targetId,
      reactor: update.reactor,
      emojis: update.emojis,
    );
  }

  /// Inserts [message], applying any held pending correction first.
  Future<void> insertMessage(MessagesCompanion message) async {
    await _db.transaction(() async {
      final targetId = message.stanzaId.present ? message.stanzaId.value : '';
      PendingCorrection? pending;
      if (targetId.isNotEmpty) {
        pending = await _db.pendingCorrection(targetId);
      }
      final effective = pending == null
          ? message
          : message.copyWith(
              body: Value(pending.body),
              editedAt: Value(pending.correctedAt),
              encMode: Value(pending.encMode),
              retracted: const Value(false),
            );

      await _db.insertMessageRow(effective);
      if (pending != null) await _db.clearPendingCorrection(targetId);
      final ts = message.timestamp.present
          ? message.timestamp.value
          : DateTime.now();
      await _db.bumpChatActivityIfNewer(message.chatJid.value, ts);
    });
  }

  /// Applies a retraction that arrived, and reports whether it changed anything.
  Future<bool> applyRetraction(String targetId, {String? by, String? reason}) =>
      markRetracted(targetId, by: by, reason: reason);

  /// Replaces the content of the message addressed by [targetId].
  Future<void> correctMessage({
    required String chatJid,
    required String targetId,
    required String body,
    required Track track,
  }) {
    return applyCorrection(
      chatJid: chatJid,
      targetId: targetId,
      body: body,
      encMode: EncModeToken.of(track).wire,
    );
  }

  /// Writes one inbound message into the store.
  ///
  /// Idempotent by stanza id. Returns whether the stored row highlighted us.
  Future<bool> storeInbound(InboundMessage msg, {String? ownBare}) async {
    final ownArchive = _isOwnArchive(msg, ownBare);
    if (ownArchive && msg.to == null) return false;
    final chatJid = _chatJidFor(msg, ownBare);
    final sender = msg.from.toString();
    final isGroupchat = msg.type == 'groupchat';
    await _db.upsertChat(chatJid, isGroup: isGroupchat ? true : null);

    if (msg.isCarbonCopy) return false;

    if (msg.retracts != null) {
      await applyRetraction(
        msg.retracts!,
        by: msg.moderatedBy,
        reason: msg.moderationReason,
      );
      return false;
    }
    if (msg.corrects != null) {
      await correctMessage(
        chatJid: chatJid,
        targetId: msg.corrects!,
        body: msg.body,
        track: msg.track ?? Track.none,
      );
      return false;
    }

    final stamp = msg.archiveTimestamp ?? DateTime.now();
    try {
      final cutoff = (await loadAutomaticMessageDeletion(appPrefs)).cutoffAt();
      if (cutoff != null && stamp.isBefore(cutoff)) return false;
    } catch (_) {}

    final chat = await _db.getChat(chatJid);
    final isGroup = chat?.isGroup ?? isGroupchat;
    final ownMuc = _isOwnMucReflection(msg, chat?.mucNick);
    final remoteId = msg.originId ?? msg.stanzaId ?? '';

    final roomId = msg.roomStanzaId;
    if (isGroupchat && roomId != null && roomId.isNotEmpty) {
      final keys = <String>{
        if ((msg.originId ?? '').isNotEmpty) msg.originId!,
        if ((msg.stanzaId ?? '').isNotEmpty) msg.stanzaId!,
      };
      for (final key in keys) {
        await _db.setRoomStanzaId(chatJid, key, roomId);
      }
    }

    if (ownMuc && remoteId.isNotEmpty) {
      if (await _db.markDelivered(chatJid, remoteId) > 0) {
        return false;
      }
    }

    final stanzaId = msg.stanzaId ?? '';
    final storedId = msg.originId ?? stanzaId;
    if (msg.retractionTombstone) {
      final targets = <String>[
        if (roomId != null && roomId.isNotEmpty) roomId,
        if (storedId.isNotEmpty) storedId,
        if (stanzaId.isNotEmpty && stanzaId != storedId) stanzaId,
      ];
      var matched = false;
      for (final id in targets) {
        if (await markRetracted(
          id,
          at: msg.retractedStamp,
          by: msg.moderatedBy,
          reason: msg.moderationReason,
        )) {
          matched = true;
        } else if (await messageAddressedBy(chatJid, id)) {
          matched = true;
        }
      }
      if (matched) return false;
    }
    if (msg.originId != null &&
        msg.originId!.isNotEmpty &&
        await _db.findByStanzaId(chatJid, msg.originId!) != null) {
      return false;
    }
    if (await _db.findByStanzaId(chatJid, stanzaId) != null) return false;
    final dedupeKey = sender.isEmpty ? stanzaId : sender;
    if (await _db.findByStanzaId(chatJid, dedupeKey) != null) return false;

    final fromMe = ownArchive || ownMuc;
    final privateMessage =
        isGroup && msg.type == 'chat' && msg.from.resource.isNotEmpty;
    final mentionsMe =
        !fromMe &&
        isGroup &&
        msg.encryptionError == null &&
        (privateMessage ||
            bodyHighlightsNick(
              msg.body,
              highlightNamesFor(nickname: chat?.mucNick, meJid: ownBare),
            ));

    await insertMessage(
      MessagesCompanion(
        chatJid: Value(chatJid),
        sender: Value(fromMe ? 'me' : sender),
        stanzaId: Value(msg.originId ?? stanzaId),
        roomStanzaId: Value(msg.roomStanzaId ?? ''),
        retracted: Value(msg.retractionTombstone),
        retractedAt: Value(msg.retractedStamp),
        retractedBy: Value(msg.moderatedBy ?? ''),
        retractedReason: Value(msg.moderationReason ?? ''),
        replyTo: Value(msg.reply?.targetId ?? ''),
        replyBody: Value(msg.reply?.body ?? ''),
        replyAuthor: Value(
          isGroupchat && msg.from.resource.isNotEmpty
              ? msg.from.resource
              : msg.from.toBare().toString(),
        ),
        body: Value(msg.encryptionError != null ? '' : msg.body),
        timestamp: Value(msg.archiveTimestamp ?? DateTime.now()),
        encMode: Value(
          msg.encryptionError != null
              ? EncModeToken.error.wire
              : await _encWireForInbound(msg),
        ),
        incoming: Value(!fromMe),
        delivered: Value(fromMe && ownMuc),
        sendStatus: Value(
          fromMe
              ? (ownMuc
                    ? MessageSendStatus.sendReceived
                    : MessageSendStatus.send)
              : MessageSendStatus.received,
        ),
        markable: Value(msg.markable),
        mediaUrl: Value(msg.encryptionError != null ? '' : msg.mediaUrl),
        mediaMime: Value(msg.mediaMime),
        mediaName: Value(msg.mediaName),
        mentionsMe: Value(mentionsMe),
      ),
    );
    return mentionsMe;
  }

  Future<String> _encWireForInbound(InboundMessage msg) async {
    final track = msg.track ?? Track.none;
    if (track == Track.none) return EncModeToken.none.wire;
    final trust = await FingerprintTrustStore(_db).aggregateActiveTrust(
      msg.from.toBare().toString(),
      omemo2: track == Track.pq,
    );
    return EncModeToken.of(track, trust: trust).wire;
  }
}

String _chatJidFor(InboundMessage msg, String? ownBare) {
  if (_isOwnArchive(msg, ownBare) && msg.to != null) {
    return msg.to!.toBare().toString();
  }
  return msg.from.toBare().toString();
}

bool _isOwnArchive(InboundMessage msg, String? ownBare) {
  if (!msg.fromArchive || ownBare == null) return false;
  return msg.from.toBare().toString() == ownBare;
}

bool _isOwnMucReflection(InboundMessage msg, String? mucNick) {
  if (msg.type != 'groupchat') return false;
  final nick = mucNick?.trim() ?? '';
  if (nick.isEmpty) return false;
  return msg.from.resource == nick;
}
