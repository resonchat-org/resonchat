// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// MessageEvent → InboundMessage. Pure mapping; no connection or DB.

import 'package:moxxmpp/moxxmpp.dart';

import 'package:resonchat/crypto/dual/track.dart';
import 'package:resonchat/xmpp/inbound/inbound_message.dart';
import 'package:resonchat/xmpp/inbound/reaction_update.dart';
import 'package:resonchat/xmpp/inbound/reply_info.dart';
import 'package:resonchat/xmpp/media/aesgcm_url.dart';
import 'package:resonchat/xmpp/stanza_id.dart';

/// Builds [InboundMessage] from a [MessageEvent], or null when the event
/// should not become a stored inbound (typing-only, spoofed moderation, etc.).
///
/// Side effects that belong on the connection (receipts, typing stream) are
/// not performed here — the caller handles those before/after mapping.
InboundMessage? inboundFromMessageEvent(
  MessageEvent event, {
  required Map<String, bool> roomStableIds,
}) {
  final error = event.encryptionError;
  final isCarbon = event.get<CarbonsData>()?.isCarbon ?? false;
  if (isCarbon && error != null) {
    return null;
  }

  final mam = event.get<MAMData>();
  final chatState = event.get<ChatState>();
  final eme = event.get<ExplicitEncryptionType>();
  final foreign = Track.isForeignEncryption(eme);
  final reactionData = event.get<MessageReactionsData>();
  final stable = event.get<StableIdData>();
  final replyData = event.get<ReplyData>();
  final retraction = event.get<MessageRetractionData>();
  final moderation = event.get<MessageModerationData>();
  if (moderation?.spoofed ?? false) return null;
  final correction = event.get<LastMessageCorrectionData>();
  final body = error != null
      ? ''
      : (reactionData != null
            ? ''
            : (event.get<MessageBodyData>()?.body ?? ''));
  final oobUrl = event.get<OOBData>()?.url?.trim() ?? '';
  final mediaUrl = () {
    if (oobUrl.isNotEmpty && AesGcmUrl.looksLikeFileUrl(oobUrl)) {
      return AesGcmUrl.primaryUrl(oobUrl);
    }
    if (AesGcmUrl.looksLikeFileUrl(body)) {
      return AesGcmUrl.primaryUrl(body);
    }
    return '';
  }();
  final hasContent =
      body.isNotEmpty ||
      mediaUrl.isNotEmpty ||
      error != null ||
      reactionData != null ||
      retraction != null ||
      (moderation != null && moderation.spoofed == false) ||
      correction != null;
  if (chatState != null && !hasContent) {
    return null;
  }
  if (!hasContent) return null;

  final tombstone =
      (retraction?.tombstone ?? false) || (moderation?.tombstone ?? false);
  final retractId = tombstone
      ? null
      : () {
          final fromRetract = retraction?.id;
          if (fromRetract != null && fromRetract.isNotEmpty) {
            return fromRetract;
          }
          final fromModeration = moderation?.stanzaId;
          if (fromModeration != null && fromModeration.isNotEmpty) {
            return fromModeration;
          }
          return null;
        }();
  final moderationReason = moderation?.reason?.trim();
  final isRoomMessage = event.type == 'groupchat';
  final roomBare = event.from.toBare().toString();
  if (mam != null &&
      isRoomMessage &&
      groupchatOnAccountArchive(
        archiveBare: mam.delay.from.toBare().toString(),
        roomBare: roomBare,
      )) {
    return null;
  }
  final roomStanzaId = isRoomMessage
      ? roomServerMessageId(
          mucArchive: mam != null,
          archiveResultId: mam?.archiveId,
          trustStanzaId: roomStableIds[roomBare.toLowerCase()] ?? false,
          stanzaIds: stable?.stanzaIds ?? const [],
          roomBare: roomBare,
        )
      : null;

  // Wire body may include a `> `-prefixed quote fallback. Strip it for the
  // stored row; the quote itself goes on [ReplyInfo.body] → replyBody.
  final wireBody = body.isNotEmpty ? body : mediaUrl;
  final reply = replyData == null
      ? null
      : ReplyInfo.from(
          replyData,
          event.get<MessageBodyData>()?.body ?? wireBody,
        );
  final displayBody = tombstone
      ? ''
      : (replyData != null ? stripFallback(replyData, wireBody) : wireBody);

  return InboundMessage(
    from: event.from,
    to: event.to,
    type: event.type,
    body: displayBody,
    stanzaId: event.id,
    encryptionError: error,
    isCarbonCopy: isCarbon,
    fromArchive: mam != null,
    archiveTimestamp: mam?.delay.timestamp,
    archiveId: mam?.archiveId,
    markable: event.get<MarkableData>()?.isMarkable ?? false,
    track: foreign ? null : Track.fromEme(eme),
    originId: stable?.originId,
    retracts: retractId,
    retractionTombstone: tombstone,
    retractedStamp: retraction?.stamp,
    moderatedBy: (moderation?.nick?.isNotEmpty ?? false)
        ? moderation!.nick
        : null,
    moderationReason: (moderationReason == null || moderationReason.isEmpty)
        ? null
        : moderationReason,
    roomStanzaId: roomStanzaId,
    corrects: correction?.id,
    mediaUrl: tombstone ? '' : mediaUrl,
    translations: tombstone
        ? const []
        : [
            for (final t
                in event.get<LangTransData>()?.translations ??
                    const <LanguageTranslation>[])
              if (t.text.trim().isNotEmpty)
                InboundTranslation(
                  lang: t.destinationLang,
                  text: t.text,
                  sourceLang: t.sourceLang ?? '',
                  engine: t.engine ?? '',
                ),
          ],
    reply: reply,
    reactions: reactionData == null
        ? null
        : ReactionUpdate(
            targetId: reactionData.messageId,
            reactor: event.type == 'groupchat' && event.from.resource.isNotEmpty
                ? event.from.resource
                : event.from.toBare().toString(),
            emojis: reactionData.emojis,
          ),
  );
}

/// Whether [event] carries enough content that a delivery receipt should fire.
bool messageEventHasContent(MessageEvent event) {
  final error = event.encryptionError;
  final reactionData = event.get<MessageReactionsData>();
  final retraction = event.get<MessageRetractionData>();
  final moderation = event.get<MessageModerationData>();
  final correction = event.get<LastMessageCorrectionData>();
  final body = error != null
      ? ''
      : (reactionData != null
            ? ''
            : (event.get<MessageBodyData>()?.body ?? ''));
  final oobUrl = event.get<OOBData>()?.url?.trim() ?? '';
  final mediaUrl = () {
    if (oobUrl.isNotEmpty && AesGcmUrl.looksLikeFileUrl(oobUrl)) {
      return AesGcmUrl.primaryUrl(oobUrl);
    }
    if (AesGcmUrl.looksLikeFileUrl(body)) {
      return AesGcmUrl.primaryUrl(body);
    }
    return '';
  }();
  return body.isNotEmpty ||
      mediaUrl.isNotEmpty ||
      error != null ||
      reactionData != null ||
      retraction != null ||
      (moderation != null && moderation.spoofed == false) ||
      correction != null;
}
