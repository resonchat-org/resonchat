// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// XMPP connection + baseline messaging (M1) with the A-track OMEMO
// manager attached (M2). All stanza crypto stays inside moxxmpp /
// omemo_dart; this class owns lifecycle and event fan-out.

import 'dart:async';

import 'package:logging/logging.dart';
import 'package:moxlib/moxlib.dart';
import 'package:moxxmpp/moxxmpp.dart';
import 'package:omemo_dart/omemo_dart_axolotl.dart' as axolotl;

import '../omemo/defacto.dart';
import '../omemo/dual_track_manager.dart';
import '../omemo/track.dart';
import '../omemo/track_resolver.dart';
import '../omemo/protocol.dart';
import '../store/omemo_device_store.dart';
import 'aesgcm_url.dart';
import 'b_track_manager.dart';
import 'blocked_inbound.dart';
import 'blocking.dart';
import 'eme.dart';
import 'http_files.dart';
import 'muc.dart';
import 'capabilities.dart';
import 'pq_incoming.dart';
import 'pq_stanza.dart';
import 'reactions.dart';
import 'replies.dart';
import 'xmpp_socket.dart';

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
    this.corrects,
    this.reply,
    this.mediaUrl = '',
    this.mediaMime = '',
    this.mediaName = '',
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

  /// The id of an earlier message this stanza retracts (XEP-0424).
  final String? retracts;

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

  /// Which track the sender used, read from its EME declaration.
  ///
  /// Null when the sender declared an encryption scheme we do not
  /// implement, or none at all. It is deliberately independent of whether
  /// [body] decrypted: a message encrypted for someone else is still labelled
  /// with the track that was used, because that is the informative part.
  final Track? track;
}

/// The server rejected one of our outgoing messages.
class DeliveryFailure {
  const DeliveryFailure({
    required this.stanzaId,
    required this.from,
    required this.reason,
  });

  /// The id we sent with, so the stored row can be found.
  final String stanzaId;

  final JID from;

  /// Human-readable cause, e.g. `auth/forbidden: Access denied by service
  /// policy`.
  final String reason;

  @override
  String toString() => 'DeliveryFailure($stanzaId from $from: $reason)';
}

/// What arrived for one inbound message, before the UI sees it.
///
/// Diagnostic counterpart to [InboundMessage]: `encrypted` plus a null
/// `decryptionError` and an empty `body` is the signature of a message we
/// could not open, whereas no entry at all means the server never routed
/// it to us.
class MessageTrace {
  const MessageTrace({
    required this.from,
    required this.encrypted,
    required this.id,
    required this.type,
    required this.error,
    required this.decryptionError,
    required this.body,
  });

  final JID from;
  final bool encrypted;
  final String? id;
  final String? type;
  final String? error;
  final String? decryptionError;
  final String body;

  @override
  String toString() => 'MessageTrace(from=$from id=$id type=$type '
      'encrypted=$encrypted error=$error decryptionError=$decryptionError '
      'body=${body.isEmpty ? "<none>" : '"$body"'})';
}

/// The peer's typing state (XEP-0085).
enum TypingState { inactive, composing, paused }

/// Delivery status of an outgoing message (M1/M2).
enum DeliveryStatus { pending, delivered }

/// A delivery receipt for a message we sent (XEP-0184).
class DeliveryReceipt {
  const DeliveryReceipt({required this.from, required this.stanzaId});

  final JID from;

  /// The id of the message stanza that was delivered.
  final String stanzaId;
}

/// A chat marker for a message we sent (XEP-0333 displayed = read).
class ReadReceipt {
  const ReadReceipt({required this.from, required this.stanzaId});

  final JID from;
  final String stanzaId;
}

/// The peer's typing state within one chat (XEP-0085).
class TypingNotification {
  const TypingNotification({required this.from, required this.state});

  final JID from;
  final TypingState state;
}

/// Connection lifecycle state surfaced to the UI.
enum XmppConnectionState { disconnected, connecting, connected }

/// Whether an outgoing stanza should be OMEMO-encrypted. M1 default is
/// plaintext; the chat UI flips this per conversation (M2/M4).
typedef ShouldEncrypt = Future<bool> Function(JID to);

/// What a send on a chosen track actually did.
///
/// [track] is the track that went out, never the one that was asked for.
/// When [blocked] is set, nothing was sent and [stanzaId] is null.
class SendOutcome {
  const SendOutcome({
    required this.stanzaId,
    required this.track,
    this.blocked,
  });

  /// Null when nothing was sent.
  final String? stanzaId;

  /// The track asked for, and — when [stanzaId] is set — the one used.
  final Track track;

  /// Why the message could not be sent, if it could not.
  final TrackBlocked? blocked;

  /// True when a stanza went out.
  bool get sent => stanzaId != null;
}

class XmppService {
  XmppService({
    ShouldEncrypt? shouldEncrypt,
    this.deviceStore,
    this.bTrack,
  }) : _shouldEncrypt = shouldEncrypt ?? ((_) async => false);

  final Logger _log = Logger('XmppService');
  ShouldEncrypt _shouldEncrypt;

  /// Where our OMEMO device keys are persisted. When null the device is
  /// generated fresh each launch (development fallback only).
  final OmemoDeviceStore? deviceStore;

  /// B-track (PQ-OMEMO) support. Null disables the PQ track entirely and
  /// leaves the app on standard OMEMO.
  final BTrackManager? bTrack;

  /// A B-track message we could not open, reported instead of swallowed.
  Stream<PqDecryptFailure> get pqFailures => _pqFailures.stream;
  final _pqFailures = StreamController<PqDecryptFailure>.broadcast();

  XmppConnection? _connection;
  PubSubManager? _pubsub;
  axolotl.AxolotlOmemoManager? _omemo;

  /// HTTP PUT/GET + aesgcm on top of registered [HttpFileUploadManager].
  late final HttpFileService httpFiles = HttpFileService(() => _connection);

  /// In-flight device initialisation, shared by racing callers.
  Future<axolotl.AxolotlOmemoManager>? _omemoInit;
  OmemoManager? _moxxOmemo;
  CarbonsManager? _carbons;
  StreamSubscription<XmppEvent>? _eventsSub;
  final _inbound = StreamController<InboundMessage>.broadcast();
  final _deliveryReceipts = StreamController<DeliveryReceipt>.broadcast();
  final _readReceipts = StreamController<ReadReceipt>.broadcast();
  final _typingStates = StreamController<TypingNotification>.broadcast();

  /// Last chat state we sent per bare JID (Conversations ChatStateManager.outgoing).
  final _outgoingChatState = <String, TypingState>{};

  /// Conversations `confirm_messages` — send XEP-0333 `<displayed/>`.
  bool sendReadReceipts = true;

  /// Conversations `chat_states` — send XEP-0085 typing notifications.
  bool sendTypingNotifications = true;

  /// Receipt requests deferred while a MAM catch-up is in flight
  /// (Conversations MessageArchiveManager.processPostponed).
  final _pendingReceiptRequests = <({JID to, String id})>[];

  /// True while [catchUpHistory] is paging; live receipts go out immediately,
  /// archived ones are queued until the catch-up finishes.
  bool _mamCatchingUp = false;

  /// Fires when a PEP node we care about changes, so cached capabilities
  /// can be dropped instead of waiting out the TTL.
  final _capabilityChanges = StreamController<JID>.broadcast();
  Stream<JID> get capabilityChanges => _capabilityChanges.stream;

  /// Stanzas that carried a reaction broadcast (XEP-0444).
  ///
  /// A separate stream from [inbound] because a reaction is not a message: it
  /// must update a bubble somewhere else in the transcript and must never be
  /// stored as one.
  Stream<InboundMessage> get reactions => _reactions.stream;
  final _reactions = StreamController<InboundMessage>.broadcast();

  XmppConnectionState _state = XmppConnectionState.disconnected;

  /// Overrides the automatic per-chat decision. Set by the settings UI.
  set shouldEncrypt(ShouldEncrypt fn) => _shouldEncrypt = fn;

  /// Consulted by [autoShouldEncrypt]; null means "derive from the
  /// capability service".
  ShouldEncrypt? _encryptOverride;

  set encryptOverride(ShouldEncrypt? fn) => _encryptOverride = fn;

  /// True when stanzas to [to] should be encrypted: either the user
  /// forced it, or the capability service says at least the standard
  /// track is safe for every recipient device.
  ///
  /// This is what moxxmpp's OmemoManager asks before wrapping a stanza,
  /// so a wrong `false` leaks plaintext while a wrong `true` produces
  /// unreadable ciphertext. We deliberately only return true when we are
  /// *sure* (docs/01 §7 invariant 1).
  Future<bool> autoShouldEncrypt(JID to) async {
    final override = _encryptOverride;
    if (override != null) return override(to);
    final caps = _capabilities == null
        ? null
        : await _capabilities!.forChat(to);
    if (caps == null || !caps.reliable) return false;
    return caps.mode != EncMode.none;
  }

  /// Capabilities for [to], or null when they could not be established.
  Future<ChatCapabilities?> capabilitiesFor(JID to) async {
    final caps = _capabilities;
    if (caps == null) return null;
    try {
      return await caps.forChat(to);
    } catch (e) {
      // A capability lookup that throws is indistinguishable, for our
      // purposes, from one that found nothing. Letting it escape would take
      // the send button down with it.
      _log.warning('capability lookup for $to failed: $e');
      return null;
    }
  }

  /// Sends [body] to [to] on exactly [track], or refuses.
  ///
  /// The single entry point for outbound chat messages. There is deliberately
  /// no variant that takes "any track that works": an argument like that is
  /// how a PQ message becomes plaintext without anybody deciding so.
  ///
  /// A blocked outcome means the message was not sent and the caller must
  /// ask the user. It does not retry on a different track.
  Future<SendOutcome> sendOnTrack(
    JID to,
    String body, {
    required Track track,
    bool requestReceipt = true,
    String? replyTo,
    String? quoteBody,
    String? quoteAuthor,
    String? oobUrl,
    /// `chat` for 1:1; `groupchat` for XEP-0045 room messages (Conversations).
    String messageType = 'chat',
  }) async {
    // Groupchat: public/anonymous → plaintext; private+non-anonymous →
    // OMEMO (and PQ when every member is fully PQ-capable) to real JIDs.
    if (messageType == 'groupchat') {
      return sendGroupchatOnTrack(
        to.toBare(),
        body,
        track: track,
        replyTo: replyTo,
        quoteBody: quoteBody,
        oobUrl: oobUrl,
      );
    }

    final caps = await capabilitiesFor(to);
    final resolution = resolveTrack(requested: track, capabilities: caps);
    if (!resolution.canSend) {
      _log.info(
        'refusing to send to $to on ${track.stored}: '
        '${resolution.blocked?.name}',
      );
      return SendOutcome(
        stanzaId: null,
        track: track,
        blocked: resolution.blocked,
      );
    }

    // The fallback body a plain-text reader sees. Built here because it has to
    // be the same text that goes into the encrypted payload and the one we
    // strip on the way back in — computing it twice is how a reply arrives with
    // its own first line quoted.
    final fallback = replyTo == null || quoteBody == null
        ? null
        : buildReplyFallback(quoteBody, body);
    final wireBody = fallback?.wireBody ?? body;

    // moxxmpp MessageManager omits <body/> when OOBData is present, so OMEMO
    // / PQ must carry the share URL in the encrypted body only. Plaintext can
    // send both (Conversations does).
    final wireOob = track == Track.none ? oobUrl : null;

    final String? stanzaId;
    switch (track) {
      case Track.pq:
        stanzaId = await sendPqMessage(
          to,
          wireBody,
          requestReceipt: requestReceipt,
          replyTo: replyTo,
          quoteBody: quoteBody,
          replyFallback: fallback,
        );
      case Track.standard:
        stanzaId = await sendOmemoMessage(
          to,
          wireBody,
          requestReceipt: requestReceipt,
          replyTo: replyTo,
          quoteBody: quoteBody,
          replyFallback: fallback,
        );
      case Track.none:
        stanzaId = await sendUnencryptedMessage(
          to,
          wireBody,
          requestReceipt: requestReceipt,
          replyTo: replyTo,
          quoteBody: quoteBody,
          replyFallback: fallback,
          oobUrl: wireOob,
        );
    }

    // A track that was judged sendable can still fail at the last moment —
    // a bundle goes stale between the check and the send. Returning the
    // requested track with a null stanza id says "nothing went out" without
    // pretending a different track was substituted.
    if (stanzaId == null) {
      return SendOutcome(
        stanzaId: null,
        track: track,
        blocked: switch (track) {
          Track.pq => TrackBlocked.pqUnavailable,
          Track.standard => TrackBlocked.standardUnavailable,
          Track.none => TrackBlocked.unreachableDevices,
        },
      );
    }
    return SendOutcome(stanzaId: stanzaId, track: track);
  }

  /// Sends a reaction broadcast (XEP-0444).
  ///
  /// Built here rather than through MessageManager, for two reasons that both
  /// come from reactions being metadata rather than content:
  ///
  ///   * `shouldEncrypt: false`. An OMEMO-wrapped reaction is invisible to
  ///     every client that is not this one — including the sender's own other
  ///     devices, and Conversations and Signal. A reaction nobody else can see
  ///     is not a reaction.
  ///   * The stanza id is minted locally rather than derived from a body. The
  ///     server may echo it back, and echoing a message with a body would show
  ///     an empty bubble in the recipient's history.
  ///
  /// [emojis] is the reactor's complete set. Passing an empty list is how a
  /// reaction is withdrawn, which is why this never merges with what is stored.
  Future<bool> setReactions(
    JID to, {
    required String targetId,
    required List<String> emojis,
  }) async {
    final connection = _connection;
    if (connection == null) return false;
    try {
      await connection.sendStanza(
        StanzaDetails(
          Stanza.message(
            to: to.toString(),
            id: _nextStanzaId(),
            type: 'chat',
            children: [MessageReactionsData(targetId, emojis).toXML()],
          ),
          awaitable: false,
          shouldEncrypt: false,
        ),
      );
      return true;
    } catch (e) {
      _log.warning('could not send reaction to $to: $e');
      return false;
    }
  }

  /// Retracts a message for everyone (XEP-0424).
  ///
  /// Sent in the clear, with the fallback body XEP-0424 specifies: the
  /// recipient's client has to be able to act on the retraction whether or not
  /// it can decrypt anything, and a client that shows nothing at all is worse
  /// than one that shows "this message was deleted".
  ///
  /// Built here rather than through MessageManager for the same reason as
  /// reactions: it must not be wrapped by the A track, and its stanza id is
  /// minted locally so an echoed retraction cannot land in the transcript as an
  /// empty bubble.
  Future<bool> retractMessage(
    JID to, {
    required String targetId,
  }) async {
    final connection = _connection;
    if (connection == null) return false;
    try {
      await connection.sendStanza(
        StanzaDetails(
          Stanza.message(
            to: to.toString(),
            id: _nextStanzaId(),
            type: 'chat',
            children: [
              XMLNode.xmlns(
                tag: 'apply-to',
                xmlns: fasteningXmlns,
                attributes: <String, String>{'id': targetId},
                children: [XMLNode.xmlns(tag: 'retract', xmlns: messageRetractionXmlns)],
              ),
              XMLNode(tag: 'body', text: 'This message has been deleted'),
              XMLNode.xmlns(tag: 'fallback', xmlns: fallbackIndicationXmlns),
            ],
          ),
          awaitable: false,
          shouldEncrypt: false,
        ),
      );
      return true;
    } catch (e) {
      _log.warning('could not retract $targetId for $to: $e');
      return false;
    }
  }

  /// Sends a correction of the message addressed by [targetId] (XEP-0308).
  ///
  /// Goes out through the normal encrypted path, because a correction *is*
  /// content: the corrected text has exactly the same claim to privacy as the
  /// original, and a correction that leaks to the server is worse than no
  /// correction at all.
  ///
  /// Refuses rather than falling back to plaintext, for the same reason
  /// [sendOnTrack] does.
  Future<SendOutcome> correctMessage(
    JID to, {
    required String targetId,
    required String body,
  }) async {
    if (targetId.isEmpty) {
      return const SendOutcome(
        stanzaId: null,
        track: Track.none,
        blocked: TrackBlocked.unreachableDevices,
      );
    }
    final caps = await capabilitiesFor(to);
    final resolution = resolveTrack(requested: Track.standard, capabilities: caps);
    if (!resolution.canSend) {
      return SendOutcome(
        stanzaId: null,
        track: Track.standard,
        blocked: resolution.blocked,
      );
    }
    final mm = _connection?.getManagerById<MessageManager>(messageManager);
    if (mm == null) throw StateError('not connected');
    final id = _nextStanzaId();
    await mm.sendMessage(
      to,
      TypedMap<StanzaHandlerExtension>.fromList([
        MessageBodyData(body),
        MessageIdData(id),
        StableIdData(id, const []),
        // XEP-0308. Without this the recipient receives an ordinary message
        // with the corrected text and now has two bubbles instead of one
        // corrected one — the correction is exactly the part that carries no
        // information on its own.
        LastMessageCorrectionData(targetId),
      ]),
      type: 'chat',
    );
    return SendOutcome(stanzaId: id, track: Track.standard);
  }

  /// Rejoins stored MODE_MULTI rooms after login (Conversations
  /// `connectMultiModeConversations`).
  Future<void> rejoinGroupChats(
    Iterable<({String roomJid, String nick})> rooms,
  ) async {
    for (final room in rooms) {
      if (room.nick.isEmpty) continue;
      final err = await joinGroupChat(room.roomJid, room.nick);
      if (err != null) {
        _log.info('rejoin ${room.roomJid} failed: $err');
      }
    }
  }

  /// Disco#info features for a room (Conversations fetch after join).
  ///
  /// Used to decide [isPrivateAndNonAnonymous] — only then may OMEMO run.
  Future<List<String>> queryRoomFeatures(String roomJid) async {
    final manager = muc;
    if (manager == null) return const [];
    final result =
        await manager.queryRoomInformation(JID.fromString(roomJid));
    if (!result.isType<RoomInformation>()) return const [];
    return List<String>.from(result.get<RoomInformation>().features);
  }

  /// Occupants currently known for [roomJid], with real JIDs when published.
  Future<List<Occupant>> roomOccupantList(String roomJid) async {
    final state = await groupChatState(roomJid);
    if (state == null) return const [];
    return state.members.values.map(Occupant.from).toList();
  }

  /// Conversations `getUsers` / `getOnlineUsers` for the member list UI.
  Future<List<Occupant>> roomDisplayMembers(String roomJid) async {
    final bare = JID.fromString(roomJid).toBare().toString();
    final online = await roomOccupantList(bare);
    final private = _privateNonAnonymous[bare] ?? false;
    return roomMembersForDisplay(
      privateNonAnonymous: private,
      affiliation: _affiliations[bare] ?? const [],
      online: online,
    );
  }

  /// Affiliation roster for OMEMO (Conversations `MucOptions.getMembers`).
  ///
  /// Falls back to presence when the admin query has not completed yet.
  Future<List<Occupant>> roomCryptoMembers(String roomJid) async {
    final bare = JID.fromString(roomJid).toBare().toString();
    final online = await roomOccupantList(bare);
    final affiliation = _affiliations[bare];
    if (affiliation == null) return online;
    return mergeRoomMembers(affiliation: affiliation, online: online);
  }

  /// After join/disco: fetch affiliation roster when private+non-anonymous
  /// (Conversations `fetchMembers`), otherwise presence-only.
  Future<void> refreshRoomMembership(
    String roomJid, {
    required bool privateNonAnonymous,
  }) async {
    final bare = JID.fromString(roomJid).toBare().toString();
    _privateNonAnonymous[bare] = privateNonAnonymous;
    if (privateNonAnonymous) {
      await fetchRoomAffiliations(bare);
    } else {
      _affiliations.remove(bare);
    }
    await _emitRoomState(bare);
  }

  /// `muc#admin` queries for owner/admin/member (Conversations `fetchMembers`).
  Future<void> fetchRoomAffiliations(String roomJid) async {
    final connection = _connection;
    if (connection == null) return;
    final bare = JID.fromString(roomJid).toBare().toString();
    final collected = <String, Occupant>{};
    for (final affiliation in const ['owner', 'admin', 'member']) {
      final items = await _queryMucAffiliation(bare, affiliation);
      for (final o in items) {
        final key = o.realJid ?? 'nick:${o.nick}';
        collected[key] = o;
      }
    }
    _affiliations[bare] = collected.values.toList();
  }

  Future<List<Occupant>> _queryMucAffiliation(
    String roomJid,
    String affiliation,
  ) async {
    final connection = _connection;
    if (connection == null) return const [];
    try {
      final result = await connection.sendStanza(
        StanzaDetails(
          Stanza.iq(
            to: roomJid,
            type: 'get',
            children: [
              XMLNode.xmlns(
                tag: 'query',
                xmlns: mucAdminXmlns,
                children: [
                  XMLNode(
                    tag: 'item',
                    attributes: {'affiliation': affiliation},
                  ),
                ],
              ),
            ],
          ),
          // Admin IQ is not a chat message; do not OMEMO-wrap it.
          shouldEncrypt: false,
        ),
      );
      if (result == null || result.attributes['type'] != 'result') {
        return const [];
      }
      final query = result.firstTag('query', xmlns: mucAdminXmlns);
      if (query == null) return const [];
      final out = <Occupant>[];
      for (final item in query.findTags('item')) {
        final o = occupantFromAdminItem(item);
        if (o != null) out.add(o);
      }
      return out;
    } catch (e) {
      _log.info('muc#admin $affiliation for $roomJid failed: $e');
      return const [];
    }
  }

  /// Whether [track] can be used for a groupchat — same checks as send,
  /// so the UI can show [askTrackSubstitute] before anything goes out
  /// (aligned with 1:1 [resolveTrack] + capabilities).
  Future<TrackResolution> resolveGroupchatTrack({
    required String roomJid,
    required Track requested,
  }) async {
    if (requested == Track.none) {
      return const TrackResolution(track: Track.none, blocked: null);
    }
    final targets = await _groupCryptoTargets(roomJid);
    if (targets.isEmpty) {
      return TrackResolution(
        track: requested,
        blocked: TrackBlocked.unknownPeers,
      );
    }
    if (requested == Track.pq) {
      final blocked = await _roomPqBlockReason(targets);
      return TrackResolution(track: Track.pq, blocked: blocked);
    }
    // Standard: member real JIDs are enough to attempt; encrypt failure is
    // reported after send, same as a stale 1:1 bundle.
    return const TrackResolution(track: Track.standard, blocked: null);
  }

  Future<List<String>> _groupCryptoTargets(String roomJid) async {
    final occupants = await roomCryptoMembers(roomJid);
    return mucCryptoTargets(occupants: occupants, ourBareJid: myJid);
  }

  /// Groupchat send: plaintext, standard OMEMO, or PQ to member real JIDs.
  Future<SendOutcome> sendGroupchatOnTrack(
    JID roomBare,
    String body, {
    required Track track,
    String? replyTo,
    String? quoteBody,
    String? oobUrl,
  }) async {
    final fallback = replyTo == null || quoteBody == null
        ? null
        : buildReplyFallback(quoteBody, body);
    final wireBody = fallback?.wireBody ?? body;

    if (track == Track.none) {
      final stanzaId = await sendUnencryptedMessage(
        roomBare,
        wireBody,
        requestReceipt: false,
        replyTo: replyTo,
        quoteBody: quoteBody,
        replyFallback: fallback,
        oobUrl: oobUrl,
        messageType: 'groupchat',
      );
      if (stanzaId == null) {
        return const SendOutcome(
          stanzaId: null,
          track: Track.none,
          blocked: TrackBlocked.unreachableDevices,
        );
      }
      return SendOutcome(stanzaId: stanzaId, track: Track.none);
    }

    final resolution = await resolveGroupchatTrack(
      roomJid: roomBare.toString(),
      requested: track,
    );
    if (!resolution.canSend) {
      return SendOutcome(
        stanzaId: null,
        track: track,
        blocked: resolution.blocked,
      );
    }

    final targets = await _groupCryptoTargets(roomBare.toString());

    if (track == Track.pq) {
      final stanzaId = await sendGroupPqMessage(
        roomBare,
        wireBody,
        recipientJids: targets,
        replyTo: replyTo,
        quoteBody: quoteBody,
        replyFallback: fallback,
      );
      if (stanzaId == null) {
        return const SendOutcome(
          stanzaId: null,
          track: Track.pq,
          blocked: TrackBlocked.pqUnavailable,
        );
      }
      return SendOutcome(stanzaId: stanzaId, track: Track.pq);
    }

    // Track.standard — Conversations ENCRYPTION_AXOLOTL for private non-anon.
    final stanzaId = await sendGroupOmemoMessage(
      roomBare,
      wireBody,
      recipientJids: targets,
      replyTo: replyTo,
      quoteBody: quoteBody,
      replyFallback: fallback,
    );
    if (stanzaId == null) {
      return const SendOutcome(
        stanzaId: null,
        track: Track.standard,
        blocked: TrackBlocked.standardUnavailable,
      );
    }
    return SendOutcome(stanzaId: stanzaId, track: Track.standard);
  }

  /// Like 1:1 PQ: every OMEMO device of every member must be PQ-capable.
  Future<TrackBlocked?> _roomPqBlockReason(List<String> memberJids) async {
    if (!bTrackReady) return TrackBlocked.pqUnavailable;
    for (final jid in memberJids) {
      final caps = await capabilitiesFor(JID.fromString(jid));
      if (caps == null || !caps.reliable) return TrackBlocked.unknownPeers;
      final allPq = caps.recipientDevices.isNotEmpty &&
          caps.recipientDevices.every(caps.pqDevices.contains);
      if (!allPq) return TrackBlocked.pqUnavailable;
    }
    return null;
  }

  /// PQ groupchat to [roomBare], keys for every PQ device of [recipientJids].
  Future<String?> sendGroupPqMessage(
    JID roomBare,
    String body, {
    required List<String> recipientJids,
    String? replyTo,
    String? quoteBody,
    ReplyFallback? replyFallback,
  }) async {
    final track = bTrack;
    if (track == null || !track.ready) return null;
    if (recipientJids.isEmpty) return null;

    // Include our bare JID so our other devices can open the copy
    // (mirrors OMEMO MUC encryptToJids + ownBare).
    final peers = <String>{
      ...recipientJids,
      ?myJid,
    }.toList();
    final encrypted = await track.encryptForPeers(
      peerJids: peers,
      plaintext: body,
    );
    if (encrypted == null) return null;

    final mm = _connection?.getManagerById<MessageManager>(messageManager);
    if (mm == null) throw StateError('not connected');
    final id = _nextStanzaId();
    await mm.sendMessage(
      roomBare,
      TypedMap<StanzaHandlerExtension>.fromList([
        MessageBodyData(encryptedBodyFallback),
        MessageIdData(id),
        StableIdData(id, const []),
        if (replyTo != null)
          ReplyData(
            replyTo,
            body: quoteBody,
            start: replyFallback?.start,
            end: replyFallback?.end,
          ),
        const EmeData(Track.pq, name: 'OMEMO-PQ'),
        PqEncryptedData(encrypted),
      ]),
      type: 'groupchat',
    );
    return id;
  }

  /// OMEMO groupchat to [roomBare], keys for [recipientJids] (member real JIDs).
  Future<String?> sendGroupOmemoMessage(
    JID roomBare,
    String body, {
    required List<String> recipientJids,
    String? replyTo,
    String? quoteBody,
    ReplyFallback? replyFallback,
  }) async {
    final connection = _connection;
    if (connection == null) throw StateError('not connected');
    if (recipientJids.isEmpty) return null;
    final id = _nextStanzaId();
    final children = <XMLNode>[
      MessageBodyData(body).toXML(),
      StableIdData(id, const []).toOriginIdElement(),
      if (replyTo != null && replyFallback != null)
        ...replyNodes(
          targetId: replyTo,
          quote: quoteBody ?? '',
          fallback: replyFallback,
        ),
    ];
    try {
      await connection.sendStanza(
        StanzaDetails(
          Stanza.message(
            to: roomBare.toString(),
            id: id,
            type: 'groupchat',
            children: children,
          ),
          awaitable: false,
          forceEncryption: true,
          omemoRecipientJids: recipientJids,
        ),
      );
      return id;
    } catch (e) {
      _log.warning('OMEMO groupchat to $roomBare failed: $e');
      return null;
    }
  }

  /// Joins a group chat at `roomJid` as [nick].
  ///
  /// Returns the error rather than throwing, because a room can refuse for a
  /// dozen ordinary reasons — name taken, room full, password required,
  /// banned — and each needs a different sentence in front of the user.
  Future<MUCError?> joinGroupChat(
    String roomJid,
    String nick, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final manager = muc;
    if (manager == null) return NoNicknameSpecified();
    // moxxmpp's joinRoom waits on a completer that its presence handler
    // completes. A MUC service that never answers — wrong address, a service
    // that is not a MUC at all, a server that drops the request — leaves that
    // completer open forever, which is a spinner that never stops and a future
    // that never returns. Bounded here rather than in moxxmpp so the reason
    // reaches the user as text.
    final result = await manager
        .joinRoom(JID.fromString(roomJid), nick)
        .timeout(
          timeout,
          // The one error type moxxmpp does not have, which is the point: a
          // service that simply did not answer is a different thing from one
          // that refused, and the user needs to be told which happened.
          onTimeout: () => Result<bool, MUCError>(MucServiceUnresponsive(roomJid)),
        );
    if (!result.isType<bool>()) return result.get<MUCError>();
    return null;
  }

  /// Leaves a group chat.
  Future<void> leaveGroupChat(String roomJid) async {
    final manager = muc;
    if (manager == null) return;
    final bare = JID.fromString(roomJid).toBare().toString();
    final result = await manager.leaveRoom(JID.fromString(roomJid));
    if (!result.isType<bool>()) {
      _log.info('leaving $roomJid failed: ${result.get<MUCError>()}');
    }
    _affiliations.remove(bare);
    _privateNonAnonymous.remove(bare);
  }

  /// The room's occupants, updated as presence arrives.
  ///
  /// A stream rather than a getter because the membership is the thing that
  /// changes: it moves on every join and every leave, including other people's
  /// devices, and a cached snapshot is wrong within seconds.
  Stream<GroupChat?> roomOccupants(String roomJid) {
    final bare = JID.fromString(roomJid).toBare().toString();
    return _roomOccupants.stream
        .where((chat) => chat?.roomJid == bare);
  }

  /// The current state of [roomJid], or null when we are not in it.
  Future<RoomState?> groupChatState(String roomJid) async =>
      await muc?.getRoomState(JID.fromString(roomJid));

  /// Blocks [items] on the server (XEP-0191).
  ///
  /// Returns false when the server refused or does not support it — which is
  /// most servers. The caller keeps the local block either way: a block the
  /// user was told about is worth honouring on this device even if nothing
  /// else learns about it, because the alternative is "blocking did not work".
  Future<bool> blockOnServer(List<String> items) async {
    final manager = _connection?.getManagerById<BlockingManager>(blockingManager);
    if (manager == null || items.isEmpty) return false;
    try {
      if (!await manager.isSupported()) return false;
      return await manager.block(items);
    } catch (e) {
      _log.warning('server refused a block for $items: $e');
      return false;
    }
  }

  /// Removes [items] from the server's block list.
  ///
  /// Best-effort and silent on failure: the local removal has already happened
  /// and telling the user "still blocked" because a server was unreachable
  /// would just teach them not to trust the button.
  Future<void> unblockOnServer(List<String> items) async {
    final manager = _connection?.getManagerById<BlockingManager>(blockingManager);
    if (manager == null || items.isEmpty) return;
    try {
      if (!await manager.isSupported()) return;
      await manager.unblock(items);
    } catch (e) {
      _log.fine('could not unblock $items on the server: $e');
    }
  }

  /// The blocked bare JIDs, consulted on every inbound message.
  ///
  /// Held on the service rather than read from the database per stanza: this is
  /// on the hot path for every message, and a database read there would be a
  /// query per message for a list that changes a handful of times a week.
  /// The blocked bare JIDs, consulted on every inbound message.
  ///
  /// Held here rather than read from the database per stanza: this is on the
  /// hot path for every message, and the list changes a handful of times a
  /// week. [AppWiring] keeps it in step with the store.
  Set<String> blockedJids = const {};

  /// A blocked contact's message we refused to open.
  Stream<BlockedMessageDropped> get blockedMessages =>
      _blockedDropped.stream;
  final _blockedDropped =
      StreamController<BlockedMessageDropped>.broadcast();

  /// The JIDs currently blocked, as last pushed by the server.
  Stream<Set<String>> get blocklistChanges => _blocklistChanges.stream;
  final _blocklistChanges =
      StreamController<Set<String>>.broadcast();

  /// Attaches the capability resolver so [autoShouldEncrypt] works.
  void attachCapabilities(CapabilityService service) =>
      _capabilities = service;
  CapabilityService? _capabilities;

  XmppConnectionState get state => _state;
  Stream<InboundMessage> get inbound => _inbound.stream;

  /// Receipts for messages we sent (XEP-0184).
  Stream<DeliveryReceipt> get deliveryReceipts => _deliveryReceipts.stream;

  /// Read markers for messages we sent (XEP-0333 `<displayed/>`).
  Stream<ReadReceipt> get readReceipts => _readReceipts.stream;

  /// Peer typing/composing notifications (XEP-0085).
  Stream<TypingNotification> get typingStates => _typingStates.stream;

  /// Every inbound message stanza as it came off the wire, before any
  /// decryption. Diagnostic counterpart to [inbound].
  Stream<MessageTrace> get rawMessages => _rawMessages.stream;
  final _rawMessages = StreamController<MessageTrace>.broadcast();

  /// Messages the server refused, keyed by the stanza id we sent them with.
  ///
  /// A `<message type='error'/>` carrying our own id means the stanza never
  /// left the server. The most common cause in practice is a service policy
  /// that refuses anything outside mutual subscriptions, which is worth
  /// telling the user about rather than showing a bubble that looks sent.
  Stream<DeliveryFailure> get deliveryFailures => _deliveryFailures.stream;
  final _deliveryFailures = StreamController<DeliveryFailure>.broadcast();

  OmemoManager? get moxxOmemo => _moxxOmemo;
  axolotl.AxolotlOmemoManager? get omemo => _omemo;

  /// PubSub/PEP manager; null until connected. The B track publishes and
  /// fetches its device list and bundles through it.
  PubSubManager? get pubsub => _pubsub;

  /// The underlying connection, for callers that need a manager this class
  /// does not wrap (roster edits, presence, diagnostics).
  XmppConnection? get connection => _connection;

  /// The XEP-0045 manager, or null before connecting.
  MUCManager? get muc => _connection?.getManagerById<MUCManager>(mucManager);

  /// The XEP-0084 avatar manager, or null before connecting.
  UserAvatarManager? get avatarManager => _connection
      ?.getManagerById<UserAvatarManager>(userAvatarManager);

  /// Our own bare JID, or null when not connected.
  ///
  /// Taken from the live session rather than stored, so a reconnect to a
  /// different account cannot leave reactions attributed to the previous one.
  String? get myJid =>
      _connection?.connectionSettings.jid.toBare().toString();

  /// Sends an "available" presence, announcing this resource to contacts.
  Future<void> sendAvailablePresence() async {
    await _connection?.getManagerById<PresenceManager>(presenceManager)
        ?.sendInitialPresence();
  }

  PresenceManager? _presenceManager() =>
      _connection?.getManagerById<PresenceManager>(presenceManager);

  /// Asks [peer] for a presence subscription.
  /// Asks [peer] to let us see their presence.
  ///
  /// Returns true when the request was actually sent. False means we already
  /// have it, or the server refused — and either way the caller should not add
  /// a pending row, or the user waits forever for an answer that is not coming.
  Future<bool> requestSubscription(JID peer) async {
    final manager = _presenceManager();
    if (manager == null) return false;
    await manager.requestSubscription(peer.toBare());
    _pendingOutgoing.add(peer.toBare().toString());
    if (!_outgoingRequests.isClosed) {
      _outgoingRequests.add(peer.toBare());
    }
    return true;
  }

  /// Bare JIDs we have asked to see, awaiting their answer.
  Stream<JID> get outgoingRequests => _outgoingRequests.stream;
  final _outgoingRequests = StreamController<JID>.broadcast();

  /// Our outgoing requests, as of right now.
  Set<String> get pendingOutgoingRequests =>
      Set.unmodifiable(_pendingOutgoing);
  final _pendingOutgoing = <String>{};

  void resolveOutgoingRequest(JID peer) =>
      _pendingOutgoing.remove(peer.toBare().toString());

  /// Grants a subscription [peer] asked for.
  ///
  /// Without this the relationship stays one-sided and most servers refuse
  /// to route messages between non-contacts, which looks exactly like a
  /// delivery bug.
  /// Declines a request.
  ///
  /// The server is told "no", which is the part that matters: a declined
  /// request means the sender is not told they are subscribed, so they cannot
  /// read our presence afterwards.
  Future<void> rejectSubscription(JID peer) async {
    await _presenceManager()?.rejectSubscriptionRequest(peer.toBare());
    resolveIncomingRequest(peer);
  }

  Future<void> acceptSubscription(JID peer) async {
    await _presenceManager()?.acceptSubscriptionRequest(peer.toBare());
  }

  /// Approves every subscription request that arrives, so a peer can add us
  /// without anyone touching the UI. Returns the peers approved.
  Stream<JID> get subscriptionRequests => _subscriptionRequests.stream;
  final _subscriptionRequests = StreamController<JID>.broadcast();

  /// True once the server accepted our Carbons enable request.
  bool get carbonsEnabled => _carbonsEnabled;
  bool _carbonsEnabled = false;

  /// Reason the last [connect] failed, for display in the UI.
  String? lastError;

  /// Whether the server advertises the MAM archive (XEP-0313). Queried
  /// lazily; cached per connection.
  bool get mamAvailable => _mamAvailable;
  bool _mamAvailable = false;

  /// Connects, logs in, and attaches roster/MAM-bootstrap managers.
  /// Returns true on successful SASL + resource binding.
  Future<bool> connect({
    required String jid,
    required String password,
    String? host,
    int? port,
    BaseRosterStateManager? rosterState,
    bool reconnect = true,
  }) async {
    await disconnect();
    _state = XmppConnectionState.connecting;
    _rosterState = rosterState;

    _moxxOmemo = OmemoManager(
      // Lazy: an OMEMO event can arrive before the device is created.
      () => _omemoOrCreate(),
      // Only chat *bodies* are encrypted. Typing notifications (XEP-0085),
      // receipt requests alone, etc. must stay clear: wrapping them as
      // empty OMEMO key-transport makes Conversations show a second
      // "could not decrypt" bubble beside the real message.
      //
      // Also ignore non-message stanzas: letting the hook run for every
      // outgoing IQ made capability resolution cascade unbounded and starve
      // login.
      (toJid, stanza) async =>
          stanza.tag == 'message' &&
          stanza.firstTag('body') != null &&
          await _shouldEncrypt(toJid),
    );
    // Default to the capability-driven decision so encryption turns on by
    // itself once both sides support OMEMO.
    _shouldEncrypt = autoShouldEncrypt;
    // Held as a local so the manager can read the blocked list through a
    // closure, and so it survives `disconnect()` — a block is a property of the
    // account, not of the session.
    final blockedInbound = BlockedInboundManager(
      () => blockedJids,
      (from) {
        final jid = from.toBare().toString();
        _log.info('dropped a message from blocked $jid before opening it');
        if (!_blockedDropped.isClosed) {
          _blockedDropped.add(
            BlockedMessageDropped(from: jid, reason: 'refused before decrypt'),
          );
        }
      },
    );
    // On web, the optional "host" field may be a full wss:// URL (manual
    // override when host-meta is missing). TCP hosts stay unchanged on IO.
    final websocketOverride =
        (host != null && (host.startsWith('wss:') || host.startsWith('ws:')))
            ? host
            : null;
    final connection = XmppConnection(
      reconnect ? TestingReconnectionPolicy() : NeverReconnectPolicy(),
      // TODO(M7): replace with a connectivity_plus-backed manager plus
      // XEP-0357 push so Doze-mode delivery works without a permanent
      // radio lock (Briar's always-on lesson, docs/09).
      AlwaysConnectedConnectivityManager(),
      ClientToServerNegotiator(),
      // Native: TCP (+ SOCKS5). Web: RFC 7395 WebSocket + XEP-0156.
      createXmppSocket(websocketUrl: websocketOverride),
    )..connectionSettings = ConnectionSettings(
        jid: JID.fromString(jid),
        // When host is a WebSocket URL, do not pass it as a TCP hostname.
        password: password,
        host: websocketOverride != null ? null : host,
        port: websocketOverride != null ? null : port,
      );

    _carbons = CarbonsManager();
    _pubsub = PubSubManager();
    final messageManager = MessageManager();
    // The B track rides along as a stanza extension, and moxxmpp only knows
    // how to serialise the ones it ships with. Without this callback the PQ
    // ciphertext is silently dropped and the stanza leaves in plaintext with
    // the "encrypted, use another client" body - the worst possible outcome:
    // it looks like it worked.
    messageManager.registerMessageSendingCallback(pqSendingCallback);
    await connection.registerManagers([
      PresenceManager(),
      RosterManager(
        rosterState ?? (_rosterState = TestingRosterStateManager(null, const [])),
      ),
      DiscoManager(const []),
      _pubsub!,
      messageManager,
      MessageDeliveryReceiptManager(),
      ChatStateManager(),
      // XEP-0333 chat markers (Conversations DisplayedManager / markable).
      ChatMarkerManager(),
      // XEP-0334 hints: chat states use no-store; receipts use store
      // (Conversations DeliveryReceiptManager / ChatStateManager).
      MessageProcessingHintManager(),
      MessageArchiveManagementManager(),
      _carbons!,
      _moxxOmemo!,
      // XEP-0363 slot discovery/request (HTTP PUT/GET stays in HttpFileService).
      HttpFileUploadManager(),
      // XEP-0066 OOB URL parse + send callback.
      OOBManager(),
      // XEP-0380. Without it the received message carries no record of which
      // track the sender used, so every encrypted message from another client
      // would be labelled as unencrypted.
      EmeManager(),
      // XEP-0084 avatars. Needs the PubSub manager, which is why it is
      // registered alongside everything else rather than lazily.
      UserAvatarManager(),
      // XEP-0045 group chats.
      MUCManager(),
      // XEP-0444 reactions, plus the stable-id manager they depend on: a
      // reaction addresses a message by its origin-id.
      StableIdManager(),
      MessageReactionsManager(),
      // XEP-0461 replies: the quoted text travels in the body fallback, the
      // reference in a <reply> element.
      MessageRepliesManager(),
      // XEP-0191 blocking. Push events matter: another of our devices
      // blocking someone has to take effect here too.
      BlockingManager(),
      // XEP-0424 and XEP-0308. Both address an earlier message by its
      // origin-id, which is why they sit next to the stable-id manager.
      MessageRetractionManager(),
      LastMessageCorrectionManager(),
      // XEP-0191: refuse a blocked contact's messages before anything opens
      // them. Ahead of the OMEMO handler by priority; registered here because
      // the only way to control that ordering is to be in the same list.
      blockedInbound,
      // B-track inbound. moxxmpp has no handler for the PQ namespace, so
      // without this an incoming PQ message arrives as the literal fallback
      // body with no error: a silent, perfectly plausible-looking delivery.
      PqIncomingManager(_decryptIncomingPq, (failure) {
        _log.warning('inbound PQ message not opened: ${failure.reason}');
        if (!_pqFailures.isClosed) _pqFailures.add(failure);
      }),
    ]);
    await connection.registerFeatureNegotiators([
      StartTlsNegotiator(),
      // Preferred order: strongest first. moxxmpp picks the first
      // negotiator whose mechanism the server advertises, so servers
      // without SCRAM-SHA-256 (e.g. conversations.im offers PLAIN and
      // SCRAM-SHA-1 only) still authenticate.
      SaslScramNegotiator(30, '', '', ScramHashType.sha256),
      SaslScramNegotiator(20, '', '', ScramHashType.sha512),
      SaslScramNegotiator(10, '', '', ScramHashType.sha1),
      SaslPlainNegotiator(),
      // Roster versioning (RFC 6121). Without this negotiator registered,
      // RosterManager.requestRoster() dereferences a null negotiator and
      // the whole roster fetch dies - which is the first thing the login
      // flow does.
      RosterFeatureNegotiator(),
      ResourceBindingNegotiator(),
    ]);

    _eventsSub = connection.asBroadcastStream().listen(_onEvent);
    final result = await connection.connect(
      shouldReconnect: reconnect,
      waitUntilLogin: true,
    );
    final ok = result.isType<bool>() && result.get<bool>();
    if (!ok) {
      // Surface the actual reason: "authentication failed" is useless
      // when the real cause is a TLS or SRV problem.
      lastError = result.isType<XmppError>()
          ? '${result.get<XmppError>()}'
          : 'connection failed (${result.dataRuntimeType})';
      _log.severe('connect failed: $lastError');
    }
    _connection = ok ? connection : null;
    _state =
        ok ? XmppConnectionState.connected : XmppConnectionState.disconnected;
    if (ok) {
      _carbonsEnabled = await _carbons!.enableCarbons();
      _mamAvailable = await _isMamAvailable();
      _log.info('carbons: $_carbonsEnabled, mam: $_mamAvailable');
      await _subscribeOwnPep();
    }
    _log.info('connect($jid): $ok');
    return ok;
  }

  /// PEP nodes worth a subscription: both OMEMO dialects plus the PQ track.
  ///
  /// The de-facto node is what real clients announce on, so subscribing
  /// only to the XEP-0384 spec node means we would never see a peer add a
  /// device.
  ///
  /// The `+notify` variants are the de-facto scheme's *push* nodes — a
  /// Conversations install subscribes to `eu.siacs.conversations.axolotl.devicelist+notify`
  /// (AxolotlService.PEP_DEVICE_LIST_NOTIFY) rather than to the bare node, and
  /// so does every other Signal-protocol client. Subscribing to the bare node
  /// still fetches, but it does not *tell* us: we then keep acting on a device
  /// list we already know is stale, which shows up as a peer gaining or losing a
  /// device and our app not noticing until something else happens to re-resolve.
  /// Both are subscribed because they cost one IQ each and only one of them
  /// answers on any given server.
  // `final`, not `const`: the `+notify` variants are built by interpolation
  // over a spread, and a const list cannot hold either. The list is created
  // once when the class is first touched and read on every connect.
  static final List<String> _subscribedPepNodes = <String>[
    omemoDefactoDevicesNode,
    '${omemoDefactoDevicesNode}+notify',
    for (final node in omemoSpecDevicesNodes) ...<String>[
      node,
      '$node+notify',
    ],
    pomemoDevicesXmlns,
    pomemoBundlesXmlns,
  ];

  /// Subscribes to our own OMEMO device list so the server pushes device
  /// changes to us (which also keeps our peers' lists fresh when they
  /// republish). Peer nodes are subscribed lazily on first use.
  Future<void> _subscribeOwnPep() async {
    final pm = _pubsub;
    if (pm == null) return;
    final bare = _connection!.connectionSettings.jid.toBare();
    for (final node in _subscribedPepNodes) {
      final result = await pm.subscribe(bare, node);
      if (!result.isType<bool>() || !result.get<bool>()) {
        _log.fine('could not subscribe to $node: $result');
      }
    }
  }

  /// Subscribes to a peer's OMEMO device list so we learn about new devices
  /// immediately instead of waiting out the capability TTL.
  Future<void> subscribePeerPep(JID peer) async {
    final pm = _pubsub;
    if (pm == null) return;
    final bare = peer.toBare();
    for (final node in _subscribedPepNodes) {
      await pm.subscribe(bare, node);
    }
  }

  /// Asks the server whether it keeps a message archive.
  Future<bool> _isMamAvailable() async {
    final dm = _connection?.getManagerById<DiscoManager>(discoManager);
    if (dm == null) return false;
    try {
      return await dm.supportsFeature(
        _connection!.connectionSettings.serverJid,
        mamXmlns,
      );
    } catch (_) {
      return false;
    }
  }

  /// Page size for MAM catch-up and per-chat history (Conversations uses 50).
  static const int mamPageSize = 50;

  /// Hard cap on catch-up pages (Conversations: MAM_MAX_MESSAGES / PAGE_SIZE).
  static const int mamCatchupMaxPages = 15;

  /// How far back a first catch-up reaches when we have no local cursor
  /// (Conversations: MAM_MAX_CATCHUP = 5 days).
  static const Duration mamCatchupInitialWindow = Duration(days: 5);

  /// Meta key for the last MAM archive id we have caught up through.
  static const String mamCatchupIdKey = 'mam_catchup_id';

  /// Meta key for the timestamp of the last caught-up archive page.
  static const String mamCatchupTsKey = 'mam_catchup_ts';

  /// Pulls archived messages for one chat (XEP-0313).
  ///
  /// Queries the **account** archive (our bare JID) with a `with` filter for
  /// [chatJid], matching Conversations. Results are replayed through the
  /// normal inbound pipeline. [beforeId] is an RSM `before` cursor for paging
  /// older history; returns the number of messages the server sent, or null
  /// on error.
  Future<int?> fetchHistory(
    JID chatJid, {
    String? beforeId,
    int? pageSize = mamPageSize,
  }) async {
    final mm =
        _connection?.getManagerById<MessageArchiveManagementManager>(
              mamManager,
            );
    final own = _connection?.connectionSettings.jid.toBare();
    if (mm == null || own == null || !_mamAvailable) return null;
    final result = await mm.requestMessages(
      own,
      withJid: chatJid.toBare(),
      rsmBefore: beforeId ?? '',
      pageSize: pageSize,
    );
    if (!result.isType<MamQueryResult>()) return null;
    return result.get<MamQueryResult>().count;
  }

  /// Catch up the account message archive after login.
  ///
  /// Aligned with Conversations `MessageArchiveManager.catchup()`:
  /// account bare JID, RSM `after` when [afterId] is known, otherwise `start`
  /// from [start] (capped to [mamCatchupInitialWindow]), page size 50, abort
  /// after [mamCatchupMaxPages] × page size (~[Config.MAM_MAX_MESSAGES]).
  ///
  /// Receipt requests seen during catch-up are postponed and flushed when the
  /// query finishes (`processPostponed`).
  Future<int?> catchUpHistory({
    String? afterId,
    DateTime? start,
    Future<void> Function(String? archiveId, DateTime? timestamp)? saveCursor,
    int pageSize = mamPageSize,
    int maxPages = mamCatchupMaxPages,
  }) async {
    final mm =
        _connection?.getManagerById<MessageArchiveManagementManager>(
              mamManager,
            );
    final own = _connection?.connectionSettings.jid.toBare();
    if (mm == null || own == null || !_mamAvailable) return null;

    // Conversations: either RSM after(reference) *or* form start(timestamp).
    var cursor = (afterId != null && afterId.isNotEmpty) ? afterId : null;
    final now = DateTime.now().toUtc();
    final windowStart = now.subtract(mamCatchupInitialWindow);
    DateTime? pageStart;
    if (cursor == null) {
      final raw = start?.toUtc();
      if (raw == null) {
        pageStart = windowStart;
      } else if (now.difference(raw) >= mamCatchupInitialWindow) {
        // Gap larger than MAM_MAX_CATCHUP → only pull the last window.
        pageStart = windowStart;
      } else {
        pageStart = raw;
      }
    }

    _mamCatchingUp = true;
    _pendingReceiptRequests.clear();
    var total = 0;
    String? lastId = cursor;
    try {
      for (var page = 0; page < maxPages; page++) {
        final result = await mm.requestMessages(
          own,
          start: pageStart,
          rsmAfter: cursor,
          pageSize: pageSize,
        );
        if (!result.isType<MamQueryResult>()) {
          _log.warning('MAM catch-up failed on page $page');
          return total == 0 ? null : total;
        }
        final pageResult = result.get<MamQueryResult>();
        total += pageResult.count;
        if (pageResult.last != null && pageResult.last!.isNotEmpty) {
          lastId = pageResult.last;
        }
        // After the first page, continue only with RSM after.
        pageStart = null;
        cursor = pageResult.last;
        _log.info(
          'MAM catch-up page $page: ${pageResult.count} msg(s), '
          'complete=${pageResult.complete}, last=$cursor',
        );
        if (pageResult.complete ||
            pageResult.count == 0 ||
            cursor == null ||
            cursor.isEmpty) {
          break;
        }
        // Conversations aborts at MAM_MAX_MESSAGES.
        if (total >= pageSize * maxPages) break;
      }
    } finally {
      _mamCatchingUp = false;
      await _flushPendingReceipts();
    }

    if (saveCursor != null) {
      await saveCursor(lastId, now);
    }
    return total;
  }

  /// Sends postponed XEP-0184 receipts after MAM catch-up
  /// (Conversations `MessageArchiveManager.processPostponed`).
  Future<void> _flushPendingReceipts() async {
    if (_pendingReceiptRequests.isEmpty) return;
    final pending = List<({JID to, String id})>.of(_pendingReceiptRequests);
    _pendingReceiptRequests.clear();
    _log.info('flushing ${pending.length} deferred delivery receipt(s)');
    for (final rr in pending) {
      await sendDeliveryReceipt(rr.to, rr.id);
    }
  }

  /// Answers a peer's XEP-0184 `<request/>` with `<received id='…'/>`.
  ///
  /// Matches Conversations `DeliveryReceiptManager.received`: same chat type
  /// and a `store` hint so the receipt is archived.
  Future<void> sendDeliveryReceipt(JID to, String id) async {
    final mm = _connection?.getManagerById<MessageManager>(messageManager);
    if (mm == null || id.isEmpty) return;
    await mm.sendMessage(
      to,
      TypedMap<StanzaHandlerExtension>.fromList([
        MessageDeliveryReceivedData(id),
        const MessageProcessingHintData([MessageProcessingHint.store]),
      ]),
      type: 'chat',
    );
  }

  /// Returns our omemo_dart manager, creating and restoring the device on
  /// first use.
  ///
  /// This is called from moxxmpp's own event handler, so it *will* run
  /// before the app has finished starting: an OMEMO device-list push or a
  /// bundle fetch can arrive during [connect], long before anything has
  /// called [ensureOmemoDevice]. Dereferencing a not-yet-created manager
  /// there crashed the connection outright, so the device is built lazily
  /// here instead.
  ///
  /// Restoring matters: a fresh device id on every start would keep
  /// appending to our own PEP device list and make peers encrypt to
  /// devices we no longer hold keys for.
  Future<axolotl.AxolotlOmemoManager> _omemoOrCreate({int opkAmount = 20}) async {
    final existing = _omemo;
    if (existing != null) return existing;
    // Several events can race here; building twice would orphan the first
    // device's keys, so the in-flight initialisation is shared.
    return _omemoInit ??= _buildOmemo(opkAmount: opkAmount).whenComplete(() {
      _omemoInit = null;
    });
  }

  Future<axolotl.AxolotlOmemoManager> _buildOmemo({required int opkAmount}) async {
    final bareJid =
        _connection!.connectionSettings.jid.toBare().toString();

    axolotl.AxolotlDevice device;
    final restored = await deviceStore?.load();
    if (restored != null && restored.jid == bareJid) {
      device = restored;
      _log.info('restored OMEMO device ${await device.deviceId}');
    } else {
      device = await axolotl.AxolotlDevice.generateNewDevice(
        bareJid,
        preKeyCount: opkAmount,
      );
      _log.info('generated new OMEMO device ${await device.deviceId}');
    }

    final manager = axolotl.AxolotlOmemoManager(
      device,
      fetchDeviceList: _fetchDeviceListDialectAware,
      fetchBundle: _fetchDeviceBundleDialectAware,
      commitDevice: (d) async {
        await deviceStore?.save(d);
      },
    );
    manager.trackPreKeyIds(device.store.preKeyStore.store.keys);
    _omemo = manager;
    return manager;
  }

  /// Device list for [jid] across both OMEMO wire dialects.
  Future<List<int>?> _fetchDeviceListDialectAware(String jid) async {
    final resolved =
        await tracks?.resolveOmemoDevices(JID.fromString(jid)) ??
            (devices: const <int>{}, listReadable: false);
    if (!resolved.listReadable) return null;
    return resolved.devices.toList();
  }

  /// Bundle for one device across both OMEMO wire dialects.
  Future<axolotl.AxolotlBundle?> _fetchDeviceBundleDialectAware(
    String jid,
    int deviceId,
  ) async {
    return tracks?.getOmemoBundle(JID.fromString(jid), deviceId);
  }

  /// Creates (or restores) our OMEMO device and publishes its bundle.
  ///
  /// Safe to call before the device exists — see [_omemoOrCreate] for why
  /// the creation cannot assume it is the first caller.
  Future<int> ensureOmemoDevice({int opkAmount = 20}) async {
    final manager = await _omemoOrCreate(opkAmount: opkAmount);
    final id = await manager.getDeviceId();
    final device = await manager.getDevice();
    final bundle = await manager.getLocalBundle();
    final bare = JID.fromString(_connection!.connectionSettings.jid.toBare().toString());

    // Publish through the dual-track manager so the bundle lands in both
    // the de-facto and the XEP-0384 dialects. Publishing only the spec form
    // makes us invisible to every client that actually exists.
    final published = tracks == null
        ? await _moxxOmemo!.publishBundle(bundle).then(
              // moxxmpp's payload bool is
              // `deviceBundlePublish.isType<PubSubError>()` — true means
              // failure.
              (r) => r.isType<bool>() && !r.get<bool>(),
              onError: (_) => false,
            )
        : await tracks!.publishOmemoBundle(bare, bundle);
    if (!published) {
      _log.warning('OMEMO bundle publish reported failure');
    }
    // Hoisted so it cannot be null-checked away across the await below: a
    // nullable public field is not promoted, and the null check would be
    // re-evaluated against a field something else can change.
    final trackManager = tracks;

    // Persist only after a confirmed publish so we never store keys the
    // server does not know about.
    if (published) {
      await deviceStore?.save(device);
      // Remember the id before pruning: the prune decides which ids are
      // candidates by asking "did this installation publish it", and the id we
      // just published is the one that has to be excluded from that set.
      await trackManager?.notePublishedDevice(id);
      // Now that our own id is on the list, drop the ones that are dead.
      //
      // Every reinstall adds an entry here and nothing ever removes one. Each
      // dead entry makes *other people's* capability resolution fail — they
      // cannot cover a device that never answers — so this is not cosmetic
      // housekeeping: left alone, a user who reinstalls a few times stops being
      // able to send to anyone at all, and nothing in the interface explains
      // why.
      if (trackManager != null) {
        final removed = await trackManager.pruneOwnDeadDevices(bare, id);
        if (removed.isNotEmpty) {
          _log.info(
            'removed ${removed.length} dead OMEMO device id(s) from our own '
            'list: $removed',
          );
          // Our device list just changed, and every cached answer about every
          // contact was derived from it. Dropping them all is cheaper than
          // working out which ones could have depended on a dead id, and being
          // wrong here means refusing to send for the rest of the TTL.
          _capabilities?.invalidateAll();
        }
      }
    }
    return id;
  }

  /// Publishes our standard-OMEMO bundle in both wire dialects.
  ///
  /// The app sets this so [ensureOmemoDevice] does not have to reach back
  /// into the provider graph.
  DualTrackManager? tracks;

  /// Tops the one-time-prekey pool back up to [target] and republishes the
  /// bundle. omemo_dart burns one OPK per new inbound session, so without
  /// this the pool drains and later sessions lose forward secrecy by
  /// falling back to the signed prekey.
  ///
  /// Call after [ensureOmemoDevice]; safe to call repeatedly.
  Future<int> replenishPrekeys({int target = 20}) async {
    final om = _omemo;
    if (om == null) return 0;
    final ids = await om.replenishPreKeys(target);
    final added = ids.length;
    if (added > 0) {
      // Keep the local copy in sync with what peers can now fetch.
      await deviceStore?.save(await om.getDevice());
    }
    return added;
  }

  /// Number of one-time prekeys still available locally.
  Future<int> availablePrekeyCount() async {
    final om = _omemo;
    if (om == null) return 0;
    return (await om.getDevice()).store.preKeyStore.store.length;
  }

  /// Creates and publishes our B-track (PQ) device.
  ///
  /// Safe to call when the B track is unavailable; returns false then.
  Future<bool> initialiseBTrack() async {
    final track = bTrack;
    if (track == null) return false;
    final bare = _connection?.connectionSettings.jid.toBare().toString();
    if (bare == null) return false;
    return track.initialise(bare);
  }

  /// Whether our PQ bundle is published and ready to use.
  bool get bTrackReady => bTrack?.ready ?? false;

  /// Fetches the roster and returns **every** entry.
  ///
  /// The returned list must come from the local cache, not from the IQ.
  /// With RFC 6121 versioning a server that has nothing to report answers
  /// with an empty `<iq/>`, and moxxmpp faithfully turns that into an empty
  /// item list — so returning it would empty the contact list on every start
  /// after the first. The cache already holds the delta applied, so it is
  /// the authoritative full roster.
  Future<List<XmppRosterItem>> requestRoster() async {
    final rm = _connection?.getManagerById<RosterManager>(rosterManager);
    if (rm == null) return const [];
    await rm.requestRoster();
    final cached = await _rosterState?.loadRosterCache();
    return cached?.roster ?? const [];
  }

  /// The roster store in use, so [requestRoster] can read the full list.
  BaseRosterStateManager? _rosterState;

  /// Opens an inbound B-track message, if this device is a recipient.
  Future<String?> _decryptIncomingPq(Stanza stanza) async {
    final payload = extractPqPayload(stanza);
    if (payload == null) return null;
    final track = bTrack;
    if (track == null || !track.ready) return null;
    final senderBare = await _pqSenderBareJid(stanza);
    if (senderBare == null) return null;
    final plaintext = await track.decryptIfPossible(
      payload,
      senderBareJid: senderBare,
    );
    if (plaintext == null) return null;
    // Each new inbound PQ session burns one one-time prekey; refilling keeps
    // forward secrecy from quietly degrading to the signed prekey for the
    // rest of this device's life.
    unawaited(track.replenishPrekeys());
    return plaintext;
  }

  /// Bare JID whose PQ bundle binds the inbound session.
  ///
  /// 1:1: stanza `from` bare. Groupchat: occupant's real JID when the room
  /// publishes it (non-anonymous); otherwise null — we cannot open a KEX
  /// without knowing who sent it.
  Future<String?> _pqSenderBareJid(Stanza stanza) async {
    final fromRaw = stanza.from;
    if (fromRaw == null || fromRaw.isEmpty) return null;
    final from = JID.fromString(fromRaw);
    if (stanza.attributes['type'] != 'groupchat') {
      return from.toBare().toString();
    }
    final state = await groupChatState(from.toBare().toString());
    final nick = from.resource;
    if (nick.isEmpty || state == null) return null;
    final member = state.members[nick];
    final real = member?.realJid;
    if (real == null) return null;
    return real.toBare().toString();
  }

  /// Serialises the B track's ciphertext

  /// Encrypts and sends [body] on the PQ track when [to] is fully PQ-capable,
  /// otherwise returns null so the caller can fall back to the A track.
  ///
  /// Never sends an encrypted message that a recipient cannot open: if the
  /// peer has no PQ devices, or encryption fails for every device, we
  /// return null instead of emitting unreadable ciphertext (invariant 1).
  Future<String?> sendPqMessage(
    JID to,
    String body, {
    bool requestReceipt = true,
    String? replyTo,
    String? quoteBody,
    ReplyFallback? replyFallback,
  }) async {
    final track = bTrack;
    if (track == null || !track.ready) return null;

    final encrypted = await track.encryptIfPossible(
      peerJid: to.toBare().toString(),
      plaintext: body,
    );
    if (encrypted == null) return null;

    final mm = _connection?.getManagerById<MessageManager>(messageManager);
    if (mm == null) throw StateError('not connected');
    final id = _nextStanzaId();

    await mm.sendMessage(
      to,
      TypedMap<StanzaHandlerExtension>.fromList([
        MessageBodyData(encryptedBodyFallback),
        MessageIdData(id),
        StableIdData(id, const []),
        if (replyTo != null)
          ReplyData(
            replyTo,
            body: quoteBody,
            start: replyFallback?.start,
            end: replyFallback?.end,
          ),
        if (requestReceipt) const MessageDeliveryReceiptData(true),
        // XEP-0333: peers may answer with <displayed/> (Conversations markable).
        const MarkableData(true),
        // XEP-0380: declare the track so the receiver can label the message
        // without decrypting it, and so a client that does not know this
        // namespace shows our name rather than guessing.
        const EmeData(Track.pq, name: 'OMEMO-PQ'),
        PqEncryptedData(encrypted),
      ]),
      type: 'chat',
    );
    return id;
  }

  /// Sends on the standard OMEMO track.
  ///
  /// No EME element here on purpose: moxxmpp's OmemoManager adds the
  /// declaration itself, and only once it has actually encrypted the stanza.
  /// Adding a second one from this side would either duplicate the element
  /// or, worse, claim encryption on a message that went out in plaintext.
  ///
  /// The caller has already established that the standard track is reachable
  /// for every recipient device, which is also what tells moxxmpp's
  /// `shouldEncrypt` hook to wrap this stanza.
  Future<String?> sendOmemoMessage(
    JID to,
    String body, {
    bool requestReceipt = true,
    String? replyTo,
    String? quoteBody,
    ReplyFallback? replyFallback,
  }) async {
    final mm = _connection?.getManagerById<MessageManager>(messageManager);
    if (mm == null) throw StateError('not connected');
    final id = _nextStanzaId();
    await mm.sendMessage(
      to,
      TypedMap<StanzaHandlerExtension>.fromList([
        MessageBodyData(body),
        MessageIdData(id),
        if (replyTo != null)
          ReplyData(
            replyTo,
            body: quoteBody,
            start: replyFallback?.start,
            end: replyFallback?.end,
          ),
        if (requestReceipt) const MessageDeliveryReceiptData(true),
        const MarkableData(true),
      ]),
      type: 'chat',
    );
    return id;
  }

  /// Sends a chat message in the clear, requesting a delivery receipt
  /// (XEP-0184).
  ///
  /// Only reachable once the user has chosen [Track.none] and been told what
  /// it means. There is no capability check here and deliberately no
  /// encryption attempt: this method does exactly one thing, so there is no
  /// path where calling it "for safety" quietly encrypts, and none where
  /// failing to encrypt produces something that looks protected.
  Future<String?> sendUnencryptedMessage(
    JID to,
    String body, {
    bool requestReceipt = true,
    String? replyTo,
    String? quoteBody,
    ReplyFallback? replyFallback,
    String? oobUrl,
    /// `chat` (1:1) or `groupchat` (XEP-0045 to bare room).
    String messageType = 'chat',
  }) async {
    final connection = _connection;
    if (connection == null) throw StateError('not connected');
    final id = _nextStanzaId();

    // Built here rather than through MessageManager so `shouldEncrypt: false`
    // is stated on the stanza itself.
    //
    // The alternative — flipping a shared flag that the `shouldEncrypt` hook
    // reads — makes the decision depend on which send happens to be in flight
    // at the moment the hook runs. A plaintext send racing an encrypted one to
    // the same contact would then take the wrong one with it. Per-stanza is
    // the only place this can be decided without a race.
    final isGroup = messageType == 'groupchat';
    final children = <XMLNode>[
      MessageBodyData(body).toXML(),
      StableIdData(id, const []).toOriginIdElement(),
      if (replyTo != null && replyFallback != null)
        ...replyNodes(
          targetId: replyTo,
          quote: quoteBody ?? '',
          fallback: replyFallback,
        ),
      if (oobUrl != null && oobUrl.isNotEmpty) OOBData(oobUrl, null).toXML(),
      // Receipts / markable are 1:1 (and private MUC) affordances; groupchat
      // reflections do not answer XEP-0184 the same way (Conversations).
      if (requestReceipt && !isGroup) MessageDeliveryReceiptData(true).toXML(),
      if (!isGroup) const MarkableData(true).toXML(),
    ];
    await connection.sendStanza(
      StanzaDetails(
        Stanza.message(
          to: to.toString(),
          id: id,
          type: messageType,
          children: children,
        ),
        awaitable: false,
        shouldEncrypt: false,
      ),
    );
    return id;
  }

  /// Publishes our typing state to [to] (XEP-0085).
  ///
  /// Aligned with Conversations `ChatStateManager`:
  /// - gated by [sendTypingNotifications] (`chat_states` pref)
  /// - only send when the state actually changes
  /// - empty composer → `active` (DEFAULT_CHAT_STATE)
  /// - idle after typing → `paused`
  /// - `no-store` hint so the notification is not archived
  Future<void> sendChatState(JID to, TypingState state) async {
    if (!sendTypingNotifications) return;
    final mm = _connection?.getManagerById<MessageManager>(messageManager);
    if (mm == null) return;
    final bare = to.toBare().toString();
    if (_outgoingChatState[bare] == state) return;
    _outgoingChatState[bare] = state;
    final xmppState = switch (state) {
      TypingState.composing => ChatState.composing,
      TypingState.paused => ChatState.paused,
      // Conversations Config.DEFAULT_CHAT_STATE = Active.
      TypingState.inactive => ChatState.active,
    };
    await mm.sendMessage(
      to,
      TypedMap<StanzaHandlerExtension>.fromList([
        xmppState,
        const MessageProcessingHintData([MessageProcessingHint.noStore]),
      ]),
      type: 'chat',
    );
  }

  /// Sends XEP-0333 `<displayed id='…'/>` for a message we have read.
  ///
  /// Conversations `DisplayedManager.displayed` — gated by [sendReadReceipts].
  Future<void> sendDisplayedMarker(JID to, String messageId) async {
    if (!sendReadReceipts) return;
    final mm = _connection?.getManagerById<MessageManager>(messageManager);
    if (mm == null || messageId.isEmpty) return;
    await mm.sendMessage(
      to,
      TypedMap<StanzaHandlerExtension>.fromList([
        ChatMarkerData(ChatMarker.displayed, messageId),
        const MessageProcessingHintData([MessageProcessingHint.store]),
      ]),
      type: 'chat',
    );
  }

  var _stanzaCounter = 0;

  /// Locally-unique stanza id. XEP-0184 receipts reference this value.
  String _nextStanzaId() {
    _stanzaCounter++;
    return 'resonchat-${DateTime.now().microsecondsSinceEpoch}-$_stanzaCounter';
  }

  Future<void> disconnect() async {
    await _eventsSub?.cancel();
    _eventsSub = null;
    await _connection?.disconnect();
    _connection = null;
    _state = XmppConnectionState.disconnected;
  }

  /// Republishes a room's state after any presence event for it.
  ///
  /// Re-read from the manager rather than patched from the event, because the
  /// events arrive in an order the server chooses and a patch applied in the
  /// wrong order leaves the member list permanently wrong with nothing to
  /// correct it.
  final _roomOccupants = StreamController<GroupChat?>.broadcast();

  /// Affiliation stubs from `muc#admin` (owner/admin/member), keyed by bare room.
  final _affiliations = <String, List<Occupant>>{};

  /// Whether [roomJid] is Conversations `isPrivateAndNonAnonymous`.
  final _privateNonAnonymous = <String, bool>{};

  Future<void> _publishRoomState(XmppEvent event) async {
    final roomJid = switch (event) {
      MemberJoinedEvent e => e.roomJid,
      MemberChangedEvent e => e.roomJid,
      MemberLeftEvent e => e.roomJid,
      MemberChangedNickEvent e => e.roomJid,
      OwnDataChangedEvent e => e.roomJid,
      _ => null,
    };
    if (roomJid == null) return;
    await _emitRoomState(roomJid.toBare().toString());
  }

  /// Emit display roster: full affiliation list when private+non-anon,
  /// otherwise online-only (Conversations `getUsers` / `getOnlineUsers`).
  Future<void> _emitRoomState(String roomJid) async {
    final bare = JID.fromString(roomJid).toBare().toString();
    final state = await groupChatState(bare);
    if (state == null || _roomOccupants.isClosed) return;
    final online = state.members.values.map(Occupant.from).toList();
    final private = _privateNonAnonymous[bare] ?? false;
    final occupants = roomMembersForDisplay(
      privateNonAnonymous: private,
      affiliation: _affiliations[bare] ?? const [],
      online: online,
    );
    _roomOccupants.add(
      GroupChat(
        roomJid: bare,
        // A room with no nick is one we are not in; showing the member list of
        // a room we only queried would be a list of people we are not talking
        // to.
        nick: state.nick ?? '',
        occupants: occupants,
        joined: state.joined,
      ),
    );
  }

  void _onEvent(XmppEvent event) {
    if (event is MessageEvent) {
      final error = event.encryptionError;
      // Our own message coming back as an error: it was refused, not
      // delivered. Report it before anything else so the UI can correct the
      // stored row instead of leaving a bubble that looks sent.
      final stanzaError = event.error;
      if (stanzaError != null && event.id != null && !event.encrypted) {
        if (!_deliveryFailures.isClosed) {
          _deliveryFailures.add(
            DeliveryFailure(
              stanzaId: event.id!,
              from: event.from,
              reason: describeStanzaError(stanzaError),
            ),
          );
        }
        return;
      }
      // A carbon is our own message from another resource: it must not be
      // stored as an inbound bubble (docs/03 §4).
      final isCarbon = event.get<CarbonsData>()?.isCarbon ?? false;
      // An undecryptable carbon is not a lost message. It is one of our own
      // outgoing messages mirrored to this resource, encrypted for the
      // *peer's* devices — we were never a recipient, so nobody lost
      // anything. Showing "Unable to decrypt" for it invents a problem.
      if (isCarbon && error != null) {
        _log.fine(
          'dropping undecryptable carbon from ${event.from}: '
          'we were not a recipient of our own message',
        );
        return;
      }
      final mam = event.get<MAMData>();
      final chatState = event.get<ChatState>();
      if (chatState != null && !isCarbon) {
        // Conversations ChatStateManager.process: update UI on change.
        // A body message often carries `active` too — that clears the
        // "is typing" indicator rather than being ignored.
        _typingStates.add(
          TypingNotification(
            from: event.from,
            state: switch (chatState) {
              ChatState.composing => TypingState.composing,
              ChatState.paused => TypingState.paused,
              _ => TypingState.inactive,
            },
          ),
        );
      }
      // XEP-0380: the sender's declaration of what it used. Absent means
      // plaintext, which is the only honest reading.
      final eme = event.get<ExplicitEncryptionType>();
      final foreign = Track.isForeignEncryption(eme);
      // XEP-0444: a stanza may carry reactions and no body. It is still a
      // message event, so without this it would land in the transcript as an
      // empty bubble above the one it reacts to.
      final reactionData = event.get<MessageReactionsData>();
      final stable = event.get<StableIdData>();
      final replyData = event.get<ReplyData>();
      final retraction = event.get<MessageRetractionData>();
      final correction = event.get<LastMessageCorrectionData>();
      final body = error != null
          ? ''
          : (reactionData != null
              ? ''
              : (event.get<MessageBodyData>()?.body ?? ''));
      // XEP-0066: Conversations puts the upload URL in OOB as well as body.
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
      final hasContent = body.isNotEmpty ||
          mediaUrl.isNotEmpty ||
          error != null ||
          reactionData != null ||
          retraction != null ||
          correction != null;
      // Chat-state-only stanzas are not stored (Conversations treats them as
      // presence-like notifications).
      if (chatState != null && !hasContent) {
        return;
      }

      // XEP-0184: answer `<request/>` like Conversations DeliveryReceiptManager.
      // Live → send immediately; catch-up → postpone until processPostponed.
      final receiptRequested =
          event.get<MessageDeliveryReceiptData>()?.receiptRequested ?? false;
      if (receiptRequested &&
          event.id != null &&
          event.id!.isNotEmpty &&
          !isCarbon &&
          hasContent) {
        if (mam != null || _mamCatchingUp) {
          _pendingReceiptRequests.add((to: event.from, id: event.id!));
        } else {
          unawaited(sendDeliveryReceipt(event.from, event.id!));
        }
      }

      if (!hasContent) return;

      final inbound = InboundMessage(
        from: event.from,
        to: event.to,
        type: event.type,
        body: body.isNotEmpty ? body : mediaUrl,
        stanzaId: event.id,
        encryptionError: error,
        isCarbonCopy: isCarbon,
        fromArchive: mam != null,
        archiveTimestamp: mam?.delay.timestamp,
        archiveId: mam?.archiveId,
        markable: event.get<MarkableData>()?.isMarkable ?? false,
        track: foreign ? null : Track.fromEme(eme),
        originId: stable?.originId,
        retracts: retraction?.id,
        corrects: correction?.id,
        mediaUrl: mediaUrl,
        reply: replyData == null
            ? null
            : ReplyInfo.from(
                replyData,
                event.get<MessageBodyData>()?.body ?? '',
              ),
        reactions: reactionData == null
            ? null
            : ReactionUpdate(
                targetId: reactionData.messageId,
                reactor: event.type == 'groupchat' &&
                        event.from.resource.isNotEmpty
                    ? event.from.resource
                    : event.from.toBare().toString(),
                emojis: reactionData.emojis,
              ),
      );
      _inbound.add(inbound);
      if (reactionData != null) _reactions.add(inbound);
    } else if (event is ChatMarkerEvent) {
      // XEP-0333: <received/> is delivery; <displayed/> is read
      // (Conversations DisplayedManager / delivery path).
      if (event.type == ChatMarker.displayed) {
        if (!_readReceipts.isClosed) {
          _readReceipts.add(
            ReadReceipt(from: event.from, stanzaId: event.id),
          );
        }
      } else if (event.type == ChatMarker.received) {
        if (!_deliveryReceipts.isClosed) {
          _deliveryReceipts.add(
            DeliveryReceipt(from: event.from, stanzaId: event.id),
          );
        }
      }
    } else if (event is DeliveryReceiptReceivedEvent) {
      _deliveryReceipts.add(
        DeliveryReceipt(from: event.from, stanzaId: event.id),
      );
    } else if (event is MemberJoinedEvent ||
        event is MemberChangedEvent ||
        event is MemberLeftEvent ||
        event is MemberChangedNickEvent ||
        event is OwnDataChangedEvent) {
      unawaited(_publishRoomState(event));
    } else if (event is BlocklistBlockPushEvent) {
      // Another of our devices blocked these. As authoritative as tapping the
      // button here, which is the whole reason this is a server-side list.
      if (!_blocklistChanges.isClosed) {
        _blocklistChanges.add(event.items.toSet());
      }
    } else if (event is BlocklistUnblockPushEvent) {
      if (!_blocklistChanges.isClosed) _blocklistChanges.add(const {});
    } else if (event is PubSubNotificationEvent) {
      _onPepNotification(event);
    } else if (event is MessageEvent) {
      // Raw view of every message stanza, before decryption is attempted.
      // A caller diagnosing "nothing arrived" needs to tell routing apart
      // from decryption, and only the raw form can do that.
      _rawMessages.add(
        MessageTrace(
          from: event.from,
          id: event.id,
          type: event.type,
          encrypted: event.encrypted,
          error: event.error?.toString(),
          decryptionError: event.encryptionError?.toString(),
          body: event.get<MessageBodyData>()?.body ?? '',
        ),
      );
    } else if (event is SubscriptionRequestReceivedEvent) {
      // Recorded, not approved. Auto-approving means anyone can subscribe and
      // start messaging you with no say in it, which is the whole reason a
      // subscription request exists. Approving is a decision the user makes in
      // the request list.
      //
      // Held as state, not just published as an event: a broadcast stream
      // delivers to whoever is listening *at the time*, so a request that
      // arrives before the UI is listening — a slow start, a widget rebuild, a
      // test that subscribes after asking — would be lost permanently. For
      // something the user is meant to decide on, losing it is not acceptable,
      // and "we told nobody" is indistinguishable from "it never happened".
      _pendingIncoming
          .add(JID.fromString('${event.from}').toBare().toString());
      if (!_incomingRequests.isClosed) {
        _incomingRequests.add(JID.fromString('${event.from}').toBare());
      }
      _log.info('subscription request from ${event.from}');
    }
  }

  /// Bare JIDs that have asked to see our presence, awaiting a decision.
  Stream<JID> get incomingRequests => _incomingRequests.stream;
  final _incomingRequests = StreamController<JID>.broadcast();

  /// The requests awaiting a decision, as of right now.
  ///
  /// Current state rather than a stream of arrivals, so a caller that starts
  /// listening late still sees what it missed.
  Set<String> get pendingIncomingRequests =>
      Set.unmodifiable(_pendingIncoming);
  final _pendingIncoming = <String>{};

  /// Forgets [peer]'s request locally, after it has been answered.
  void resolveIncomingRequest(JID peer) =>
      _pendingIncoming.remove(peer.toBare().toString());

  /// A peer added or removed a device, or republished a bundle. Their PQ
  /// capability may have flipped, so the cached answer must go.
  void _onPepNotification(PubSubNotificationEvent event) {
    final node = event.item.node;
    if (!_subscribedPepNodes.contains(node)) {
      return;
    }
    final owner = JID.fromString(event.from).toBare();
    _log.info('PEP change on $node by $owner; dropping cached capabilities');
    _capabilities?.invalidate(owner);
    if (!_capabilityChanges.isClosed) _capabilityChanges.add(owner);
  }
}

/// Reconnection policy that never reconnects.
///
/// Used by probes and headless tools: an automatic reconnect turns a dropped
/// stream into an unhandled socket error inside the caller's zone, which
/// buries whatever the caller was actually measuring. Reconnecting is the
/// app's job and is done deliberately, with backoff.
class NeverReconnectPolicy extends ReconnectionPolicy {
  @override
  Future<void> onSuccess() async {}

  @override
  Future<void> onFailure() async {}
}

/// Renders a stanza error as something worth showing a user.
///
/// The server's own wording is kept verbatim: "Access denied by service
/// policy" and "service-unavailable" call for completely different
/// responses, and paraphrasing them into one generic string would hide that.
String describeStanzaError(StanzaError error) {
  if (error is GenericStanzaError) {
    final text = error.text.isEmpty ? '' : ': ${error.text}';
    return '${error.type}/${error.condition}$text';
  }
  return error.toString();
}
