// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Decrypted inbound chat message DTO (wire/event mapping → domain).

import 'package:moxxmpp/moxxmpp.dart' show JID;

import 'package:resonchat/crypto/dual/track.dart';
import 'package:resonchat/xmpp/inbound/forward_info.dart';
import 'package:resonchat/xmpp/inbound/reaction_update.dart';
import 'package:resonchat/xmpp/inbound/reply_info.dart';

/// One XEP-0171 translation on an inbound message.
class InboundTranslation {
  const InboundTranslation({
    required this.lang,
    required this.text,
    this.sourceLang = '',
    this.engine = '',
  });

  final String lang;
  final String text;
  final String sourceLang;
  final String engine;
}

/// Decrypted inbound chat message, either track or plaintext.
class InboundMessage {
  InboundMessage({
    required this.from,
    required this.body,
    required this.stanzaId,
    this.to,
    this.type,
    this.encryptionError,
    this.isCarbonCopy = false,
    this.fromArchive = false,
    this.archiveTimestamp,
    this.archiveId,
    this.markable = false,
    this.track,
    this.originId,
    this.reactions,
    this.retracts,
    this.retractionTombstone = false,
    this.retractedStamp,
    this.moderatedBy,
    this.moderationReason,
    this.roomStanzaId,
    this.corrects,
    this.reply,
    this.forward,
    this.mediaUrl = '',
    this.mediaMime = '',
    this.mediaName = '',
    this.translations = const [],
  });

  final JID from;

  /// The original `to` of the stanza, when present.
  ///
  /// Needed for archived copies of our own outbound messages: [from] is us,
  /// so the conversation is [to], not [from].
  final JID? to;

  /// Stanza `type` (`chat`, `groupchat`, …). Rooms are marked from
  /// `groupchat` rather than from guessing the JID.
  final String? type;

  final String body;

  /// The stanza id, needed to acknowledge delivery (XEP-0184).
  final String? stanzaId;

  /// Non-null when decryption failed; [body] is then empty and the UI
  /// must render an "unable to decrypt" placeholder (never drop it).
  final Object? encryptionError;

  /// True when this is our own message mirrored from another device
  /// (XEP-0280). Must not be shown as an inbound chat bubble.
  final bool isCarbonCopy;

  /// True when the message came from the MAM archive (XEP-0313) rather
  /// than live delivery.
  final bool fromArchive;

  /// Original send time for archived messages; live messages use now().
  final DateTime? archiveTimestamp;

  /// MAM `<result id='…'/>` — the RSM cursor id for catch-up paging.
  final String? archiveId;

  /// True when the stanza carried XEP-0333 `<markable/>`.
  final bool markable;

  /// The sender's own stable id for this message (XEP-0359 origin-id).
  ///
  /// Preferred over [stanzaId] for addressing the message, because the server's
  /// id changes when the message is archived and replayed, while the origin-id
  /// does not. Null when the sender published no stable id — which happens with
  /// some clients, so callers must have a fallback rather than assume one.
  final String? originId;

  /// The reply metadata this message carries (XEP-0461), or null.
  ///
  /// Holds the quoted text as well as the target, because the quote has to be
  /// stored rather than looked up: the quoted message is the one most likely to
  /// be retracted, and a quote that empties out when its target is deleted is
  /// worse than no quote.
  final ReplyInfo? reply;

  /// Plaintext XEP-0297 user-forward payload, or null.
  ///
  /// Distinct from [reply]: a forward may point at another conversation.
  final ForwardInfo? forward;

  /// The id of an earlier message this stanza retracts (XEP-0424).
  ///
  /// Null on a tombstone: that stanza *is* the retracted message.
  final String? retracts;

  /// True when the archive replaced this message with a `<retracted/>` tombstone.
  final bool retractionTombstone;

  /// When the retraction happened, from a tombstone's `stamp`.
  final DateTime? retractedStamp;

  /// Moderator nick when this retraction is XEP-0425. Null for a self-retract.
  final String? moderatedBy;

  /// Reason a moderator gave (XEP-0425). Null when they gave none.
  ///
  /// A blank reason is stored as null so the transcript can omit the reason
  /// clause entirely — no comma, no label, no colon.
  final String? moderationReason;

  /// Stanza-id assigned by the room (XEP-0359), when [type] is `groupchat`.
  final String? roomStanzaId;

  /// The id of an earlier message this stanza corrects (XEP-0308).
  ///
  /// Not null only when a correction actually applies to something we can name.
  final String? corrects;

  /// A reaction broadcast carried by this same stanza, if any.
  ///
  /// Reactions arrive in their own message, but a client may attach one to a
  /// copy of the message. Kept here so the storage layer handles one shape.
  final ReactionUpdate? reactions;

  /// HTTP File Upload / OOB share URL when this message carries a file.
  final String mediaUrl;

  /// MIME hint when known; may be empty until download/sniff.
  final String mediaMime;

  /// Original file name when known.
  final String mediaName;

  /// XEP-0171 translations carried on the stanza.
  final List<InboundTranslation> translations;

  /// Which track the sender used, read from its EME declaration.
  ///
  /// Null when the sender declared an encryption scheme we do not
  /// implement, or none at all. It is deliberately independent of whether
  /// [body] decrypted: a message encrypted for someone else is still labelled
  /// with the track that was used, because that is the informative part.
  final Track? track;
}
