// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// XMPP connection + baseline messaging (M1) with the A-track OMEMO
// manager attached (M2). All stanza crypto stays inside moxxmpp /
// omemo_dart; this class owns lifecycle and event fan-out.

import 'dart:async';
import 'dart:convert';
import 'dart:math' show min;
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:moxlib/moxlib.dart';
import 'package:moxxmpp/moxxmpp.dart';
import 'package:omemo_dart/omemo_dart_axolotl.dart' as axolotl;
import 'package:omemo_dart/omemo_dart_omemo2.dart' show hybridOmemo2Fingerprint;

import 'package:resonchat/crypto/axolotl/defacto.dart';
import 'package:resonchat/crypto/dual/dual_track_manager.dart';
import 'package:resonchat/crypto/dual/fingerprint_trust.dart';
import 'package:resonchat/crypto/dual/negotiation.dart';
import 'package:resonchat/crypto/dual/track.dart';
import 'package:resonchat/crypto/dual/track_resolver.dart';
import 'package:resonchat/crypto/omemo2/protocol.dart';
import 'package:resonchat/persistence/omemo_device_store.dart';
import 'package:resonchat/persistence/prefs_database.dart';
import 'package:resonchat/xmpp/chat/replies.dart';
import 'package:resonchat/xmpp/connect_failure.dart';
import 'package:resonchat/xmpp/encryption/b_track_manager.dart';
import 'package:resonchat/xmpp/encryption/capabilities.dart';
import 'package:resonchat/xmpp/encryption/eme.dart';
import 'package:resonchat/xmpp/encryption/pq_incoming.dart';
import 'package:resonchat/xmpp/encryption/pq_stanza.dart';
import 'package:resonchat/xmpp/history_sync.dart';
import 'package:resonchat/xmpp/inbound/inbound_mapper.dart';
import 'package:resonchat/xmpp/inbound/inbound_message.dart';
import 'package:resonchat/xmpp/media/http_files.dart';
import 'package:resonchat/xmpp/muc/muc.dart';
import 'package:resonchat/xmpp/muc/muc_create.dart';
import 'package:resonchat/xmpp/muc/muc_iq.dart';
import 'package:resonchat/xmpp/muc/room_invite.dart';
import 'package:resonchat/xmpp/reconnect_policy.dart';
import 'package:resonchat/xmpp/roster/avatar.dart';
import 'package:resonchat/xmpp/roster/blocked_inbound.dart';
import 'package:resonchat/xmpp/roster/blocking.dart';
import 'package:resonchat/xmpp/roster/presence_store.dart';
import 'package:resonchat/xmpp/socket/xmpp_socket.dart';

export 'package:resonchat/xmpp/inbound/inbound_message.dart'
    show InboundMessage;

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
  String toString() =>
      'MessageTrace(from=$from id=$id type=$type '
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
    this.fingerprintTrust,
  }) : _shouldEncrypt = shouldEncrypt ?? ((_) async => false);

  final Logger _log = Logger('XmppService');
  ShouldEncrypt _shouldEncrypt;

  /// Where our OMEMO device keys are persisted. When null the device is
  /// generated fresh each launch (development fallback only).
  final OmemoDeviceStore? deviceStore;

  /// B-track (PQ-OMEMO) support. Null disables the PQ track entirely and
  /// leaves the app on standard OMEMO.
  final BTrackManager? bTrack;

  /// Per-fingerprint trust (monocles TrustKeys). Null → encrypt to every
  /// reachable device (legacy behaviour).
  final FingerprintTrustStore? fingerprintTrust;

  /// A B-track message we could not open, reported instead of swallowed.
  Stream<PqDecryptFailure> get pqFailures => _pqFailures.stream;
  final _pqFailures = StreamController<PqDecryptFailure>.broadcast();

  XmppConnection? _connection;
  PubSubManager? _pubsub;
  BookmarksManager? _bookmarks;
  axolotl.AxolotlOmemoManager? _omemo;

  /// Fires when XEP-0402 / legacy bookmarks change (fetch, push, publish).
  final _bookmarksChanges = StreamController<void>.broadcast();
  Stream<void> get bookmarksChanges => _bookmarksChanges.stream;

  /// Current bookmark cache (seeded from local DB, then refreshed by PEP).
  List<ConferenceBookmark> get cachedBookmarks =>
      _bookmarks?.bookmarks ?? const [];

  /// Loads last-known bookmarks into memory before the network fetch.
  void seedBookmarks(List<ConferenceBookmark> bookmarks) {
    _bookmarks?.seedCache(bookmarks);
  }

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

  /// Contact presence (RFC 6121), aggregated per bare JID.
  final presence = PresenceStore();
  final _presenceChanges = StreamController<void>.broadcast();
  Stream<void> get presenceChanges => _presenceChanges.stream;

  /// Our advertised availability (RFC 6121 `<show/>`).
  PresenceShow _ownShow = PresenceShow.chat;
  PresenceShow get ownShow => _ownShow;

  /// Last chat state we sent per bare JID (Conversations ChatStateManager.outgoing).
  final _outgoingChatState = <String, TypingState>{};

  /// Send XEP-0184 `<received/>` when a peer requests delivery confirmation.
  bool sendDeliveryReceipts = true;

  /// Send XEP-0333 `<displayed/>` (and advertise `<markable/>` on outbound).
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

  /// How often [livenessPing] asks the server for an answer, and how long it
  /// waits before declaring the socket dead.
  static const Duration livenessInterval = Duration(minutes: 2);
  static const Duration livenessTimeout = Duration(seconds: 20);

  /// How often an idle connection sends a whitespace keepalive.
  ///
  /// moxxmpp's own keepalive runs every five minutes, which is longer than the
  /// idle timeout of many NATs and proxies: the flow is dropped while both
  /// sides believe it is open. One whitespace byte (RFC 6120 §4.6.1) every half
  /// minute keeps the flow warm at negligible cost. Nothing answers it, so it
  /// cannot detect a dead socket — [_runLivenessPing] does that.
  static const Duration keepaliveInterval = Duration(seconds: 30);

  /// XEP-0199. XMPP's own ping, used only as a liveness probe.
  static const String pingXmlns = 'urn:xmpp:ping';

  /// Periodic liveness probe.
  ///
  /// moxxmpp's keepalive is a *whitespace* ping: no reply is expected, so it
  /// can never fail. That is fine while the socket reports its own errors, but
  /// when the peer closes the TCP connection and no closure event reaches us,
  /// the connection stays "connected" forever: every write succeeds locally,
  /// the keepalive logs "Attempting to send ping", and nothing is ever
  /// received. That is a silent dead account that never auto-reconnects.
  ///
  /// An IQ ping *does* have an answer, so a missing reply is something we can
  /// act on.
  Timer? _livenessTimer;
  Timer? _keepaliveTimer;
  bool _livenessProbeRunning = false;

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

  /// Allocates a locally-unique origin-id before the row is inserted
  /// (Conversations creates the message UUID first, then sends).
  String allocateStanzaId() => _nextStanzaId();

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

    /// Pre-allocated origin-id from [allocateStanzaId]; generated when null.
    String? originId,

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
        originId: originId,
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
          originId: originId,
        );
      case Track.standard:
        stanzaId = await sendOmemoMessage(
          to,
          wireBody,
          requestReceipt: requestReceipt,
          replyTo: replyTo,
          quoteBody: quoteBody,
          replyFallback: fallback,
          originId: originId,
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
          originId: originId,
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
  /// Sent in the clear. The fallback body is for clients that do not
  /// understand retraction; a supporting client must not show it.
  ///
  /// [groupchat] selects `type='groupchat'` and expects [targetId] to be the
  /// room's stanza-id. A 1:1 retraction uses the message `id`.
  ///
  /// Built here rather than through MessageManager for the same reason as
  /// reactions: it must not be wrapped by the A track, and its stanza id is
  /// minted locally so an echoed retraction cannot land in the transcript as an
  /// empty bubble.
  Future<bool> retractMessage(
    JID to, {
    required String targetId,
    bool groupchat = false,
  }) async {
    final connection = _connection;
    if (connection == null || targetId.isEmpty) return false;
    try {
      await connection.sendStanza(
        StanzaDetails(
          Stanza.message(
            to: to.toString(),
            id: _nextStanzaId(),
            type: groupchat ? 'groupchat' : 'chat',
            children: messageRetractionNodes(targetId),
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

  /// Asks [room] to retract someone else's message (XEP-0425).
  ///
  /// [stanzaId] is the room's stanza-id. The room applies it and broadcasts
  /// the retraction; this returns true only when the IQ result is `result`.
  Future<bool> moderateMessage(JID room, {required String stanzaId}) async {
    final manager = _connection?.getManagerById<MessageModerationManager>(
      messageModerationManager,
    );
    if (manager == null || stanzaId.isEmpty) return false;
    try {
      return await manager.moderate(room: room.toBare(), stanzaId: stanzaId);
    } catch (e) {
      _log.warning('could not moderate $stanzaId in $room: $e');
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
    final resolution = resolveTrack(
      requested: Track.standard,
      capabilities: caps,
    );
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

  /// Fetches PEP bookmarks (XEP-0402, else legacy conversion).
  Future<List<ConferenceBookmark>> fetchBookmarks() async {
    final bm = _bookmarks;
    if (bm == null) return const [];
    final result = await bm.fetch();
    if (result.isType<PubSubError>()) {
      _log.info('fetchBookmarks failed: ${result.get<PubSubError>()}');
      return bm.bookmarks;
    }
    if (!_bookmarksChanges.isClosed) _bookmarksChanges.add(null);
    return result.get<List<ConferenceBookmark>>();
  }

  /// Publishes / updates one conference bookmark (autojoin by default).
  Future<bool> publishConferenceBookmark({
    required String roomJid,
    String? name,
    String? nick,
    String? password,
    bool autoJoin = true,
  }) async {
    final bm = _bookmarks;
    if (bm == null) return false;
    final result = await bm.publish(
      ConferenceBookmark(
        jid: roomJid,
        name: name,
        nick: nick,
        password: password,
        autoJoin: autoJoin,
      ),
    );
    if (result.isType<PubSubError>()) {
      _log.info('publishBookmark failed: ${result.get<PubSubError>()}');
      return false;
    }
    if (!_bookmarksChanges.isClosed) _bookmarksChanges.add(null);
    return true;
  }

  /// Removes a conference bookmark.
  Future<bool> retractConferenceBookmark(String roomJid) async {
    final bm = _bookmarks;
    if (bm == null) return false;
    final result = await bm.retract(roomJid);
    if (result.isType<PubSubError>()) {
      _log.info('retractBookmark failed: ${result.get<PubSubError>()}');
      return false;
    }
    if (!_bookmarksChanges.isClosed) _bookmarksChanges.add(null);
    return true;
  }

  /// Disco#info features for a room (Conversations fetch after join).
  ///
  /// Used to decide [isPrivateAndNonAnonymous] — only then may OMEMO run.
  /// Also caches `muc#roominfo_changesubject` / `muc#roomconfig_changesubject`
  /// for [canChangeSubject].
  Future<List<String>> queryRoomFeatures(String roomJid) async {
    final info = await queryRoomInformation(roomJid);
    if (info == null) return const [];
    return List<String>.from(info.features);
  }

  /// Full disco#info for a room, or null when the query fails.
  ///
  /// [RoomInformation.name] is the conference identity name — what the UI
  /// should show instead of the bare JID / localpart.
  Future<RoomInformation?> queryRoomInformation(String roomJid) async {
    final manager = muc;
    if (manager == null) return null;
    final bare = JID.fromString(roomJid).toBare().toString();
    final result = await manager.queryRoomInformation(JID.fromString(bare));
    if (!result.isType<RoomInformation>()) return null;
    final info = result.get<RoomInformation>();
    _cacheRoomPolicy(bare, info);
    return info;
  }

  /// True when disco#info says [jid] is a MUC / conference entity.
  ///
  /// Conversations never adds those addresses as roster contacts
  /// (`findOrCreateConversation(..., muc=true)`). Used before `addToRoster`.
  Future<bool> discoSuggestsMuc(String jid) async {
    final dm = disco;
    if (dm == null) return false;
    final bare = JID.fromString(jid).toBare();
    try {
      final result = await dm.discoInfoQuery(bare, shouldCache: false);
      if (!result.isType<DiscoInfo>()) return false;
      final info = result.get<DiscoInfo>();
      for (final identity in info.identities) {
        if (identity.category == 'conference') return true;
      }
      return info.features.contains(mucXmlns);
    } catch (_) {
      return false;
    }
  }

  /// XEP-0077 password change. The caller stores the new password and reconnects.
  Future<bool> changePassword(String password) async {
    final manager = _connection?.getManagerById<InBandRegistrationManager>(
      inBandRegistrationManager,
    );
    if (manager == null) return false;
    final result = await manager.setPassword(password);
    return result.isType<bool>() && result.get<bool>();
  }

  /// XEP-0077 `<remove/>`. Local account data stays until the caller deletes it.
  Future<bool> unregisterAccount() async {
    final manager = _connection?.getManagerById<InBandRegistrationManager>(
      inBandRegistrationManager,
    );
    if (manager == null) return false;
    final result = await manager.unregister();
    return result.isType<bool>() && result.get<bool>();
  }

  /// Removes [jid] from the roster (Conversations `deleteContactOnServer`).
  ///
  /// The chat transcript is left in place. [RosterRemovalResult.itemNotFound]
  /// counts as success: the contact is already gone.
  Future<bool> removeContact(String jid) async {
    final roster = _connection?.getManagerById<RosterManager>(rosterManager);
    if (roster == null) return false;
    final bare = JID.fromString(jid).toBare().toString();
    final result = await roster.removeFromRoster(bare);
    return result == RosterRemovalResult.okay ||
        result == RosterRemovalResult.itemNotFound;
  }

  /// Drops [jid] from the roster if present (rooms are not contacts).
  Future<void> removeFromRosterIfPresent(String jid) async {
    final roster = _connection?.getManagerById<RosterManager>(rosterManager);
    if (roster == null) return;
    final bare = JID.fromString(jid).toBare().toString();
    try {
      await roster.removeFromRoster(bare);
    } catch (e) {
      _log.fine('removeFromRoster $bare: $e');
    }
  }

  /// Conversations `MucOptions.canChangeSubject`:
  /// moderator role OR room allows participants to edit the subject.
  Future<bool> canChangeSubject(String roomJid) async {
    final bare = JID.fromString(roomJid).toBare().toString();
    final state = await groupChatState(bare);
    if (state == null || !state.joined) return false;
    if (state.role == Role.moderator) return true;
    return _participantsCanChangeSubject[bare] ?? false;
  }

  /// True when we are a moderator in [roomJid] and the room advertises
  /// XEP-0425, so we can retract other people's messages.
  Future<bool> canModerate(String roomJid) async {
    final bare = JID.fromString(roomJid).toBare().toString();
    final state = await groupChatState(bare);
    if (state == null || !state.joined) return false;
    if (state.role != Role.moderator) return false;
    return _roomModeration[bare] ?? false;
  }

  /// Snapshot of what the self occupant may do in [roomJid].
  Future<RoomSelfCapabilities> roomSelfCapabilities(String roomJid) async {
    final bare = JID.fromString(roomJid).toBare().toString();
    final state = await groupChatState(bare);
    final affiliation = state?.affiliation?.value ?? 'none';
    final role = state?.role?.value ?? 'none';
    final joined = state?.joined ?? false;
    final membersOnly = _membersOnly[bare] ?? false;
    final allowInvites = _allowInvites[bare] ?? false;
    return RoomSelfCapabilities(
      affiliation: affiliation,
      role: role,
      joined: joined,
      privateNonAnonymous: _privateNonAnonymous[bare] ?? false,
      allowPm: allowPrivateMessages(
        allowPmRaw: _allowPmRaw[bare],
        selfRole: role,
      ),
      canInvite: canInviteToRoom(
        joined: joined,
        membersOnly: membersOnly,
        allowInvites: allowInvites,
        selfRole: role,
      ),
      canChangeSubject:
          joined &&
          (state?.role == Role.moderator ||
              (_participantsCanChangeSubject[bare] ?? false)),
    );
  }

  /// Conversations `MultiUserChatManager.setSubject`.
  Future<void> setGroupChatSubject(String roomJid, String subject) async {
    final manager = muc;
    if (manager == null) return;
    await manager.setSubject(JID.fromString(roomJid).toBare(), subject);
  }

  /// Publish XEP-0172 nick (Conversations `publishDisplayName`).
  Future<bool> publishDisplayName(String name) async {
    final manager = nick;
    if (manager == null) return false;
    final result = await manager.publish(name);
    return result.isType<bool>() && result.get<bool>();
  }

  /// Publish own XEP-0084 avatar from raw image bytes.
  Future<bool> publishOwnAvatarBytes(
    Uint8List bytes, {
    bool public = true,
  }) async {
    final manager = avatarManager;
    if (manager == null) return false;
    final prepared = await prepareAvatarImage(bytes);
    if (prepared == null) return false;
    return publishOwnAvatar(manager, prepared, public: public);
  }

  /// MUC room avatar via vCard PHOTO (Conversations `publishMucAvatar`).
  /// Owner-only on the server; callers must gate with [RoomSelfCapabilities.canConfigureRoom].
  Future<bool> publishMucAvatar(String roomJid, Uint8List bytes) async {
    final manager = vcard;
    if (manager == null) return false;
    final prepared = await prepareAvatarImage(bytes);
    if (prepared == null) return false;
    final result = await manager.publishPhoto(
      JID.fromString(roomJid).toBare(),
      prepared.mimeType,
      prepared.bytes,
    );
    return result.isType<bool>() && result.get<bool>();
  }

  /// Owner-only room name (`muc#roomconfig_roomname`), Conversations
  /// `ConferenceDetailsActivity.onMucInfoUpdated`.
  Future<bool> setRoomName(String roomJid, String name) async {
    return applyRoomConfigOptions(roomJid, {
      'muc#roomconfig_persistentroom': true,
      'muc#roomconfig_roomname': name.trim(),
    });
  }

  /// Disco `muc#roominfo_description` (Conversations `Room.of`).
  ///
  /// Not the MUC subject/topic: subject is a live groupchat field; description
  /// is the natural-language blurb from room configuration / disco.
  Future<String?> queryRoomDescription(String roomJid) async {
    final info = await queryRoomInformation(roomJid);
    final values = info?.roomInfo
        ?.getFieldByVar('muc#roominfo_description')
        ?.values;
    if (values == null || values.isEmpty) return null;
    final v = values.first.trim();
    return v.isEmpty ? null : v;
  }

  /// Owner-only room description (`muc#roomconfig_roomdesc`, XEP-0045).
  Future<bool> setRoomDescription(String roomJid, String description) async {
    return applyRoomConfigOptions(roomJid, {
      'muc#roomconfig_persistentroom': true,
      'muc#roomconfig_roomdesc': description.trim(),
    });
  }

  /// Merge [options] into the room owner config form and submit
  /// (Conversations `MultiUserChatManager.pushConfiguration`).
  Future<bool> applyRoomConfigOptions(
    String roomJid,
    Map<String, Object> options,
  ) async {
    final form = await fetchRoomConfigForm(roomJid);
    if (form == null) return false;
    final fields = <DataFormField>[];
    final applied = <String>{};
    for (final f in form.fields) {
      final key = f.varAttr;
      if (key != null && options.containsKey(key)) {
        applied.add(key);
        fields.add(
          DataFormField(
            varAttr: f.varAttr,
            type: f.type,
            label: f.label,
            description: f.description,
            isRequired: f.isRequired,
            values: [roomConfigFormValue(options[key]!)],
            options: f.options,
          ),
        );
      } else {
        fields.add(f);
      }
    }
    for (final entry in options.entries) {
      if (applied.contains(entry.key)) continue;
      fields.add(
        DataFormField(
          varAttr: entry.key,
          type: entry.value is bool ? 'boolean' : 'text-single',
          isRequired: false,
          values: [roomConfigFormValue(entry.value)],
          options: const [],
        ),
      );
    }
    return submitRoomConfigForm(
      roomJid,
      DataForm(
        type: 'submit',
        title: form.title,
        instructions: form.instructions,
        fields: fields,
        reported: form.reported,
        items: form.items,
      ),
    );
  }

  /// First MUC host from disco (Conversations `getMucService`).
  Future<String?> discoverMucServiceHost() async {
    final dm = disco;
    if (dm == null) return null;
    var services = dm.mucServices;
    if (services.isEmpty) {
      await dm.performDiscoSweep();
      services = dm.mucServices;
    }
    if (services.isNotEmpty) {
      return services.first.toBare().toString();
    }
    // Fallback conference.<domain> when disco lists none.
    final bare = myJid;
    if (bare == null) return null;
    final at = bare.indexOf('@');
    if (at < 0 || at >= bare.length - 1) return null;
    return 'conference.${bare.substring(at + 1)}';
  }

  /// Conversations `createPrivateGroupChat`: join new room → private config →
  /// invite [inviteeJids].
  Future<CreateRoomResult> createPrivateGroupChat({
    String? name,
    List<String> inviteeJids = const [],
    String? nick,
  }) async {
    final service = await discoverMucServiceHost();
    if (service == null) {
      return const CreateRoomResult.fail('no_muc_service');
    }
    final roomJid = '${pronounceableRoomLocalpart()}@$service';
    return _createAndConfigureRoom(
      roomJid: roomJid,
      nick: nick,
      name: name,
      options: defaultGroupChatConfiguration(name: name),
      inviteeJids: inviteeJids,
    );
  }

  /// Conversations `createPublicChannel`.
  Future<CreateRoomResult> createPublicChannel({
    required String roomJid,
    String? name,
    String? nick,
  }) async {
    final bare = JID.fromString(roomJid).toBare().toString();
    if (!bare.contains('@') || bare.endsWith('@')) {
      return const CreateRoomResult.fail('invalid_jid');
    }
    return _createAndConfigureRoom(
      roomJid: bare,
      nick: nick,
      name: name,
      options: defaultChannelConfiguration(name: name),
    );
  }

  Future<CreateRoomResult> _createAndConfigureRoom({
    required String roomJid,
    required Map<String, Object> options,
    String? name,
    String? nick,
    List<String> inviteeJids = const [],
  }) async {
    final joinNick = (nick ?? _defaultMucNick()).trim();
    if (joinNick.isEmpty) {
      return const CreateRoomResult.fail('no_nick');
    }
    final joinErr = await joinGroupChat(roomJid, joinNick);
    if (joinErr != null) {
      return CreateRoomResult.fail('$joinErr');
    }
    final configured = await applyRoomConfigOptions(roomJid, options);
    if (!configured) {
      _log.warning('create room $roomJid: config submit failed (room joined)');
    }
    for (final invitee in inviteeJids) {
      final jid = invitee.trim();
      if (jid.isEmpty) continue;
      await inviteToRoom(roomJid, jid);
    }
    final features = await queryRoomFeatures(roomJid);
    return CreateRoomResult.ok(
      roomJid: roomJid,
      nick: joinNick,
      title: (name != null && name.trim().isNotEmpty) ? name.trim() : roomJid,
      privateNonAnonymous: isPrivateAndNonAnonymous(features),
    );
  }

  String _defaultMucNick() {
    final bare = myJid;
    if (bare == null) return '';
    final at = bare.indexOf('@');
    return at > 0 ? bare.substring(0, at) : bare;
  }

  /// XEP-0045 §10.9 destroy room (Conversations `MultiUserChatManager.destroy`).
  /// Owner-only on the server.
  Future<bool> destroyRoom(String roomJid) async {
    final connection = _connection;
    if (connection == null) return false;
    final bare = JID.fromString(roomJid).toBare().toString();
    try {
      final result = await connection
          .sendStanza(
            StanzaDetails(
              Stanza.iq(
                to: bare,
                type: 'set',
                children: [mucOwnerDestroyQuery()],
              ),
              shouldEncrypt: false,
            ),
          )
          .timeout(const Duration(seconds: 20));
      if (result == null || result.attributes['type'] != 'result') {
        return false;
      }
      await leaveGroupChat(bare);
      return true;
    } catch (e) {
      _log.warning('destroyRoom $bare: $e');
      return false;
    }
  }

  /// XEP-0045 §10.2 — request the room configuration data form (`muc#owner`).
  ///
  /// [lang] is sent as `xml:lang` so servers that localize forms (e.g. ejabberd)
  /// can return translated labels; Prosody often returns English only.
  Future<DataForm?> fetchRoomConfigForm(String roomJid, {String? lang}) async {
    final connection = _connection;
    if (connection == null) return null;
    final bare = JID.fromString(roomJid).toBare().toString();
    try {
      final result = await connection
          .sendStanza(
            StanzaDetails(
              Stanza.iq(
                to: bare,
                type: 'get',
                attributes: {
                  if (lang != null && lang.isNotEmpty) 'xml:lang': lang,
                },
                children: [mucOwnerGetQuery()],
              ),
              shouldEncrypt: false,
            ),
          )
          .timeout(const Duration(seconds: 20));
      if (result == null || result.attributes['type'] != 'result') return null;
      return parseMucOwnerConfigForm(result);
    } catch (e) {
      _log.warning('fetchRoomConfigForm $bare: $e');
      return null;
    }
  }

  /// Submit a filled room configuration form (`type=submit`).
  Future<bool> submitRoomConfigForm(String roomJid, DataForm form) async {
    final connection = _connection;
    if (connection == null) return false;
    final bare = JID.fromString(roomJid).toBare().toString();
    try {
      final result = await connection
          .sendStanza(
            StanzaDetails(
              Stanza.iq(
                to: bare,
                type: 'set',
                children: [mucOwnerSubmitQuery(form)],
              ),
              shouldEncrypt: false,
            ),
          )
          .timeout(const Duration(seconds: 20));
      return result != null && result.attributes['type'] == 'result';
    } catch (e) {
      _log.warning('submitRoomConfigForm $bare: $e');
      return false;
    }
  }

  /// Cancel an in-progress room configuration session.
  Future<void> cancelRoomConfigForm(String roomJid) async {
    final connection = _connection;
    if (connection == null) return;
    final bare = JID.fromString(roomJid).toBare().toString();
    try {
      await connection.sendStanza(
        StanzaDetails(
          Stanza.iq(to: bare, type: 'set', children: [mucOwnerCancelQuery()]),
          shouldEncrypt: false,
        ),
      );
    } catch (e) {
      _log.warning('cancelRoomConfigForm $bare: $e');
    }
  }

  /// Gajim kick: set role to `none` (does not ban).
  Future<bool> kickOccupant(String roomJid, Occupant occupant) async {
    final bare = JID.fromString(roomJid).toBare().toString();
    final caps = await roomSelfCapabilities(bare);
    if (!canKickOccupant(
      selfRole: caps.role,
      selfAffiliation: caps.affiliation,
      target: occupant,
    )) {
      return false;
    }
    if (occupant.nick.isEmpty) return false;
    return setRoomRole(bare, occupant.nick, 'none');
  }

  /// Gajim ban: set affiliation to `outcast` (needs a real bare JID).
  Future<bool> banOccupant(String roomJid, Occupant occupant) async {
    final bare = JID.fromString(roomJid).toBare().toString();
    final caps = await roomSelfCapabilities(bare);
    final real = occupant.realJid;
    if (real == null || real.isEmpty) return false;
    if (!canChangeOccupantAffiliation(
      selfAffiliation: caps.affiliation,
      target: occupant,
      toAffiliation: 'outcast',
    )) {
      return false;
    }
    return setRoomAffiliation(bare, real, 'outcast');
  }

  /// Grant (`participant`) or revoke (`visitor`) voice — Gajim mod menu.
  Future<bool> setOccupantVoice(
    String roomJid,
    Occupant occupant, {
    required bool grant,
  }) async {
    final bare = JID.fromString(roomJid).toBare().toString();
    final caps = await roomSelfCapabilities(bare);
    if (!canChangeOccupantRole(
      selfRole: caps.role,
      selfAffiliation: caps.affiliation,
      target: occupant,
    )) {
      return false;
    }
    if (occupant.nick.isEmpty || !occupant.isOnline) return false;
    return setRoomRole(bare, occupant.nick, grant ? 'participant' : 'visitor');
  }

  /// Change affiliation (Make Owner / Admin / Member / Revoke Member).
  Future<bool> setOccupantAffiliation(
    String roomJid,
    Occupant occupant,
    String affiliation,
  ) async {
    final bare = JID.fromString(roomJid).toBare().toString();
    final caps = await roomSelfCapabilities(bare);
    final real = occupant.realJid;
    if (real == null || real.isEmpty) return false;
    if (!canChangeOccupantAffiliation(
      selfAffiliation: caps.affiliation,
      target: occupant,
      toAffiliation: affiliation,
    )) {
      return false;
    }
    return setRoomAffiliation(bare, real, affiliation);
  }

  /// Conversations `MultiUserChatManager.invite` (mediated invite).
  Future<bool> inviteToRoom(String roomJid, String inviteeBareJid) async {
    final connection = _connection;
    if (connection == null) return false;
    final bare = JID.fromString(roomJid).toBare().toString();
    final caps = await roomSelfCapabilities(bare);
    if (!caps.canInvite) return false;
    final invitee = JID.fromString(inviteeBareJid).toBare().toString();
    // Members-only rooms need affiliation before the invite is useful.
    if (_membersOnly[bare] ?? false) {
      await setRoomAffiliation(bare, invitee, 'member');
    }
    try {
      await connection.sendStanza(
        StanzaDetails(
          Stanza.message(
            to: bare,
            children: [
              XMLNode.xmlns(
                tag: 'x',
                xmlns: mucUserXmlns,
                children: [
                  XMLNode(tag: 'invite', attributes: {'to': invitee}),
                ],
              ),
            ],
          ),
          awaitable: false,
          shouldEncrypt: false,
        ),
      );
      return true;
    } catch (e) {
      _log.warning('invite to $bare failed: $e');
      return false;
    }
  }

  /// `muc#admin` set affiliation (Conversations `setAffiliation`).
  Future<bool> setRoomAffiliation(
    String roomJid,
    String userBareJid,
    String affiliation,
  ) async {
    final connection = _connection;
    if (connection == null) return false;
    final bare = JID.fromString(roomJid).toBare().toString();
    final user = JID.fromString(userBareJid).toBare().toString();
    try {
      final result = await connection.sendStanza(
        StanzaDetails(
          Stanza.iq(
            to: bare,
            type: 'set',
            children: [
              mucAdminSetAffiliationQuery(
                userBareJid: user,
                affiliation: affiliation,
              ),
            ],
          ),
          shouldEncrypt: false,
        ),
      );
      return result != null && result.attributes['type'] == 'result';
    } catch (e) {
      _log.warning('setAffiliation $affiliation for $user in $bare: $e');
      return false;
    }
  }

  /// `muc#admin` set role (Conversations `setRole`).
  Future<bool> setRoomRole(String roomJid, String nick, String role) async {
    final connection = _connection;
    if (connection == null) return false;
    final bare = JID.fromString(roomJid).toBare().toString();
    try {
      final result = await connection.sendStanza(
        StanzaDetails(
          Stanza.iq(
            to: bare,
            type: 'set',
            children: [mucAdminSetRoleQuery(nick: nick, role: role)],
          ),
          shouldEncrypt: false,
        ),
      );
      return result != null && result.attributes['type'] == 'result';
    } catch (e) {
      _log.warning('setRole $role for $nick in $bare: $e');
      return false;
    }
  }

  void _cacheRoomPolicy(String bare, RoomInformation info) {
    final key = bare.toLowerCase();
    _roomMam[key] = info.features.contains(mamXmlns);
    _roomStableIds[key] = info.features.contains(stableIdXmlns);
    _membersOnly[bare] = info.features.contains('muc_membersonly');
    _roomModeration[bare] = info.features.contains(messageModerateXmlns);
    final form = info.roomInfo;
    if (form == null) {
      _participantsCanChangeSubject[bare] = false;
      _allowInvites[bare] = false;
      _allowPmRaw[bare] = null;
      return;
    }
    final subjectField =
        form.getFieldByVar('muc#roomconfig_changesubject') ??
        form.getFieldByVar('muc#roominfo_changesubject');
    _participantsCanChangeSubject[bare] =
        subjectField != null &&
        subjectField.values.isNotEmpty &&
        subjectField.values.first == '1';

    final inviteField = form.getFieldByVar('muc#roomconfig_allowinvites');
    _allowInvites[bare] =
        inviteField != null &&
        inviteField.values.isNotEmpty &&
        inviteField.values.first == '1';

    final pmField = form.getFieldByVar('muc#roomconfig_allowpm');
    _allowPmRaw[bare] = (pmField == null || pmField.values.isEmpty)
        ? null
        : pmField.values.first;
  }

  /// Occupants currently known for [roomJid], with real JIDs when published.
  Future<List<Occupant>> roomOccupantList(String roomJid) async {
    final state = await groupChatState(roomJid);
    if (state == null) return const [];
    return state.members.values.map(Occupant.from).toList();
  }

  /// Live affiliation+presence merge for [roomJid] (may be empty / nick-only).
  Future<List<Occupant>> _liveRoomMembers(String bare) async {
    final online = await roomOccupantList(bare);
    return roomMembersForDisplay(
      includeOfflineAffiliates: _includeOfflineAffiliates[bare] ?? false,
      affiliation: _affiliations[bare] ?? const [],
      online: online,
    );
  }

  /// Member list for the UI (members page, read rings, crypto targets).
  ///
  /// Always local-first via [resolveRoomRoster]: saved roster until live has
  /// real JIDs (or any live when we never had JIDs).
  Future<List<Occupant>> roomDisplayMembers(String roomJid) async {
    final bare = JID.fromString(roomJid).toBare().toString();
    final saved = savedRoomMembers(bare);
    final live = await _liveRoomMembers(bare);
    return resolveRoomRoster(live: live, saved: saved);
  }

  /// Last display roster written for [roomJid], if any.
  List<Occupant> savedRoomMembers(String roomJid) =>
      List<Occupant>.of(_savedMembers[_roomKey(roomJid)] ?? const []);

  /// [GroupChat] the UI should show (member list + read rings).
  ///
  /// Uses [roomDisplayMembers] so offline / pre-join opens still get the
  /// persisted roster; live MUC state only supplies nick/subject/joined.
  Future<GroupChat?> roomChatForDisplay(String roomJid) async {
    final bare = JID.fromString(roomJid).toBare().toString();
    final occupants = await roomDisplayMembers(bare);
    final state = await groupChatState(bare);
    if (state == null) {
      if (occupants.isEmpty) return null;
      return GroupChat(
        roomJid: bare,
        nick: '',
        occupants: occupants,
        joined: false,
        canSeeMemberJids: roomRosterHasRealJids(occupants),
      );
    }
    return GroupChat(
      roomJid: bare,
      nick: state.nick ?? '',
      occupants: occupants,
      subject: state.subject,
      joined: state.joined,
      canSeeMemberJids:
          roomCanSeeMemberJids(bare) || roomRosterHasRealJids(occupants),
    );
  }

  /// Offline snapshot from the persisted roster (paint before join/disco).
  GroupChat? localRoomChat(String roomJid, {required String nick}) {
    final bare = JID.fromString(roomJid).toBare().toString();
    final saved = savedRoomMembers(bare);
    if (saved.isEmpty) return null;
    return GroupChat(
      roomJid: bare,
      nick: nick,
      occupants: saved,
      joined: false,
      canSeeMemberJids: roomRosterHasRealJids(saved),
    );
  }

  /// Loads rosters saved by [onRoomRoster]. Called before connect so a marker
  /// that arrives with the first presence can already map nick → real JID.
  void restoreRoomMembers(Map<String, String> jsonByBareJid) {
    _savedMembers
      ..clear()
      ..addAll({
        for (final entry in jsonByBareJid.entries)
          entry.key.trim().toLowerCase(): decodeRoomMembers(entry.value),
      });
  }

  String _roomKey(String roomJid) =>
      JID.fromString(roomJid).toBare().toString().toLowerCase();

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

  /// After join/disco: fetch affiliations when we can see real JIDs
  /// (non-anonymous, or owner/admin) or when private+non-anonymous (OMEMO).
  Future<void> refreshRoomMembership(
    String roomJid, {
    required bool privateNonAnonymous,
    required bool nonAnonymous,
  }) async {
    final bare = JID.fromString(roomJid).toBare().toString();
    _privateNonAnonymous[bare] = privateNonAnonymous;
    _nonAnonymous[bare] = nonAnonymous;
    final caps = await roomSelfCapabilities(bare);
    final includeOffline = canSeeRoomMemberJids(
      nonAnonymous: nonAnonymous,
      selfAffiliation: caps.affiliation,
    );
    _includeOfflineAffiliates[bare] = includeOffline;
    // muc#admin needs privilege; also keep Conversations private-group fetch.
    if (includeOffline || privateNonAnonymous) {
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
            children: [mucAdminGetAffiliationQuery(affiliation)],
          ),
          // Admin IQ is not a chat message; do not OMEMO-wrap it.
          shouldEncrypt: false,
        ),
      );
      if (result == null || result.attributes['type'] != 'result') {
        return const [];
      }
      return parseMucAdminOccupants(result);
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

    /// Pre-allocated origin-id from [allocateStanzaId]; generated when null.
    String? originId,
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
        originId: originId,
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
        originId: originId,
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
      originId: originId,
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

  /// Group PQ: each member needs a non-empty OMEMO2 device list (B-track
  /// only — not ∩ with classic devices).
  Future<TrackBlocked?> _roomPqBlockReason(List<String> memberJids) async {
    if (!bTrackReady) return TrackBlocked.pqUnavailable;
    for (final jid in memberJids) {
      final caps = await capabilitiesFor(JID.fromString(jid));
      if (caps == null || !caps.pqReliable) return TrackBlocked.unknownPeers;
      if (caps.pqDevices.isEmpty) return TrackBlocked.pqUnavailable;
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
    String? originId,
  }) async {
    final track = bTrack;
    if (track == null || !track.ready) return null;
    if (recipientJids.isEmpty) return null;

    // Include our bare JID so our other devices can open the copy
    // (mirrors OMEMO MUC encryptToJids + ownBare).
    final peers = <String>{...recipientJids, ?myJid}.toList();
    final encrypted = await track.encryptForPeers(
      peerJids: peers,
      plaintext: body,
    );
    if (encrypted == null) return null;

    final mm = _connection?.getManagerById<MessageManager>(messageManager);
    if (mm == null) throw StateError('not connected');
    final id = originId ?? _nextStanzaId();
    // monocles generateOmemo2Chat: OMEMO2 ciphertext only — never hand the
    // fallback body to classic axolotl (MessageManager defaults shouldEncrypt).
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
        if (sendReadReceipts &&
            (_privateNonAnonymous[roomBare.toBare().toString()] ?? false))
          const MarkableData(true),
      ]),
      type: 'groupchat',
      shouldEncrypt: false,
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
    String? originId,
  }) async {
    final connection = _connection;
    if (connection == null) throw StateError('not connected');
    if (recipientJids.isEmpty) return null;
    final id = originId ?? _nextStanzaId();
    final children = <XMLNode>[
      MessageBodyData(body).toXML(),
      StableIdData(id, const []).toOriginIdElement(),
      if (replyTo != null && replyFallback != null)
        ...replyNodes(
          targetId: replyTo,
          quote: quoteBody ?? '',
          fallback: replyFallback,
        ),
      if (sendReadReceipts &&
          (_privateNonAnonymous[roomBare.toBare().toString()] ?? false))
        const MarkableData(true).toXML(),
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
    final bare = JID.fromString(roomJid).toBare().toString();
    // Disco before presence so a MAM room joins with no XEP-0045 history
    // (Conversations `history.setMaxStanzas(0)` when `mamSupport()`).
    var info = await queryRoomInformation(bare);
    var mam = _roomMam[bare.toLowerCase()] ?? false;
    // moxxmpp's joinRoom waits on a completer that its presence handler
    // completes. A MUC service that never answers — wrong address, a service
    // that is not a MUC at all, a server that drops the request — leaves that
    // completer open forever, which is a spinner that never stops and a future
    // that never returns. Bounded here rather than in moxxmpp so the reason
    // reaches the user as text.
    final result = await manager
        .joinRoom(JID.fromString(bare), nick, maxHistoryStanzas: mam ? 0 : null)
        .timeout(
          timeout,
          // The one error type moxxmpp does not have, which is the point: a
          // service that simply did not answer is a different thing from one
          // that refused, and the user needs to be told which happened.
          onTimeout: () =>
              Result<bool, MUCError>(MucServiceUnresponsive(roomJid)),
        );
    if (!result.isType<bool>()) return result.get<MUCError>();
    if (info == null) {
      await queryRoomInformation(bare);
      mam = _roomMam[bare.toLowerCase()] ?? false;
    }
    // Conversations `catchupMUC` after a join into a MAM room. The room's
    // `<result id='…'/>` is the stanza-id the live reflection may not have
    // carried yet.
    if (mam) unawaited(_catchUpRoomArchive(bare));
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
    _nonAnonymous.remove(bare);
    _includeOfflineAffiliates.remove(bare);
    _participantsCanChangeSubject.remove(bare);
    _allowInvites.remove(bare);
    _allowPmRaw.remove(bare);
    _membersOnly.remove(bare);
    _roomModeration.remove(bare);
  }

  /// The room's occupants, updated as presence arrives.
  ///
  /// A stream rather than a getter because the membership is the thing that
  /// changes: it moves on every join and every leave, including other people's
  /// devices, and a cached snapshot is wrong within seconds.
  Stream<GroupChat?> roomOccupants(String roomJid) {
    final bare = JID.fromString(roomJid).toBare().toString();
    return _roomOccupants.stream.where((chat) => chat?.roomJid == bare);
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
    final manager = _connection?.getManagerById<BlockingManager>(
      blockingManager,
    );
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
    final manager = _connection?.getManagerById<BlockingManager>(
      blockingManager,
    );
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
  Stream<BlockedMessageDropped> get blockedMessages => _blockedDropped.stream;
  final _blockedDropped = StreamController<BlockedMessageDropped>.broadcast();

  /// The JIDs currently blocked, as last pushed by the server.
  Stream<Set<String>> get blocklistChanges => _blocklistChanges.stream;
  final _blocklistChanges = StreamController<Set<String>>.broadcast();

  /// Attaches the capability resolver so [autoShouldEncrypt] works.
  void attachCapabilities(CapabilityService service) => _capabilities = service;
  CapabilityService? _capabilities;

  XmppConnectionState get state => _state;
  Stream<XmppConnectionState> get stateChanges => _stateChanges.stream;
  final _stateChanges = StreamController<XmppConnectionState>.broadcast();

  void _setState(XmppConnectionState next) {
    if (_state == next) return;
    _state = next;
    if (!_stateChanges.isClosed) _stateChanges.add(next);
  }

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

  DiscoManager? get disco =>
      _connection?.getManagerById<DiscoManager>(discoManager);

  NickManager? get nick =>
      _connection?.getManagerById<NickManager>(nickManager);

  VCardManager? get vcard =>
      _connection?.getManagerById<VCardManager>(vcardManager);

  /// The XEP-0084 avatar manager, or null before connecting.
  UserAvatarManager? get avatarManager =>
      _connection?.getManagerById<UserAvatarManager>(userAvatarManager);

  /// Our own bare JID, or null when not connected.
  ///
  /// Taken from the live session rather than stored, so a reconnect to a
  /// different account cannot leave reactions attributed to the previous one.
  String? get myJid => _connection?.connectionSettings.jid.toBare().toString();

  /// Sends an "available" presence, announcing this resource to contacts.
  Future<void> sendAvailablePresence() async {
    await _presenceManager()?.sendPresence(show: _ownShow);
  }

  /// Sets and (when connected) broadcasts our RFC 6121 availability.
  Future<void> setOwnPresence(PresenceShow show) async {
    _ownShow = show;
    final manager = _presenceManager();
    if (manager == null) return;
    manager.configure(show: show);
    if (_state == XmppConnectionState.connected) {
      await manager.sendPresence(show: show);
    }
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

  /// Incoming MUC invitations (mediated or direct).
  Stream<RoomInvite> get roomInvites =>
      _roomInviteManager?.invites ?? const Stream.empty();

  RoomInviteManager? _roomInviteManager;

  /// XEP-0045 `<decline/>` for a mediated invite we are rejecting.
  Future<void> declineRoomInvite({
    required String roomJid,
    String toInviter = '',
  }) async {
    final conn = _connection;
    if (conn == null) return;
    final children = <XMLNode>[
      XMLNode(
        tag: 'decline',
        attributes: {if (toInviter.isNotEmpty) 'to': toInviter},
      ),
    ];
    try {
      await conn.sendStanza(
        StanzaDetails(
          Stanza.message(
            to: JID.fromString(roomJid).toBare().toString(),
            children: [
              XMLNode.xmlns(tag: 'x', xmlns: mucUserXmlns, children: children),
            ],
          ),
          awaitable: false,
          shouldEncrypt: false,
        ),
      );
    } catch (e) {
      _log.warning('decline invite to $roomJid failed: $e');
    }
  }

  /// Bare JIDs we have asked to see, awaiting their answer.
  Stream<JID> get outgoingRequests => _outgoingRequests.stream;
  final _outgoingRequests = StreamController<JID>.broadcast();

  /// Our outgoing requests, as of right now.
  Set<String> get pendingOutgoingRequests => Set.unmodifiable(_pendingOutgoing);
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

  /// Why the last [connect] failed, for the UI to put in its own words.
  ///
  /// An enum rather than a string: moxxmpp's error classes define no
  /// `toString()`, so interpolating one produced `Instance of
  /// 'NoConnectionPossibleError'` on the login screen, and the wording is the
  /// UI's business anyway — it has to be localized, and this layer has no
  /// business holding user-facing text.
  XmppConnectFailure? lastFailure;

  /// Whether this room's disco result advertised MAM. False until disco runs.
  bool roomMamAvailable(String roomJid) =>
      _roomMam[roomJid.trim().toLowerCase()] ?? false;

  Future<HistorySyncSetting> _loadHistorySync() async {
    try {
      return await loadHistorySyncSetting(appPrefs);
    } catch (_) {
      return HistorySyncSetting.fallback;
    }
  }

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
    _setState(XmppConnectionState.connecting);
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
      // monocles: ENCRYPTION_AXOLOTL vs ENCRYPTION_AXOLOTL_OMEMO2 are
      // mutually exclusive send paths. A stanza that already carries
      // `<encrypted xmlns='urn:monocles:omemo-pq:1'/>` must not be wrapped
      // again by classic OMEMO — that re-encrypts the fallback body and the
      // peer only ever reads "Use a supported client…".
      (toJid, stanza) async =>
          stanza.tag == 'message' &&
          stanza.firstTag('body') != null &&
          stanza.firstTag('encrypted', xmlns: omemo2Xmlns) == null &&
          await _shouldEncrypt(toJid),
    );
    // Default to the capability-driven decision so encryption turns on by
    // itself once both sides support OMEMO.
    _shouldEncrypt = autoShouldEncrypt;
    // Held as a local so the manager can read the blocked list through a
    // closure, and so it survives `disconnect()` — a block is a property of the
    // account, not of the session.
    final blockedInbound = BlockedInboundManager(() => blockedJids, (from) {
      final jid = from.toBare().toString();
      _log.info('dropped a message from blocked $jid before opening it');
      if (!_blockedDropped.isClosed) {
        _blockedDropped.add(
          BlockedMessageDropped(from: jid, reason: 'refused before decrypt'),
        );
      }
    });
    // On web, the optional "host" field may be a full wss:// URL (manual
    // override when host-meta is missing). TCP hosts stay unchanged on IO.
    final websocketOverride =
        (host != null && (host.startsWith('wss:') || host.startsWith('ws:')))
        ? host
        : null;
    // monocles XmppConnection.getTimeToNextAttempt: exponential backoff on
    // stream/TCP loss. TestingReconnectionPolicy is a no-op stub — using it
    // left the app permanently offline after the first socket error.
    final connection =
        XmppConnection(
            reconnect
                ? MonoclesBackoffReconnectionPolicy()
                : NeverReconnectPolicy(),
            // TODO(M7): replace with a connectivity_plus-backed manager plus
            // XEP-0357 push so Doze-mode delivery works without a permanent
            // radio lock (Briar's always-on lesson, docs/09).
            AlwaysConnectedConnectivityManager(),
            ClientToServerNegotiator(),
            // Native: TCP (+ SOCKS5). Web: RFC 7395 WebSocket + XEP-0156.
            createXmppSocket(websocketUrl: websocketOverride),
          )
          ..connectionSettings = ConnectionSettings(
            jid: JID.fromString(jid),
            // When host is a WebSocket URL, do not pass it as a TCP hostname.
            password: password,
            host: websocketOverride != null ? null : host,
            port: websocketOverride != null
                ? null
                : (port ?? (host != null && host.isNotEmpty ? 5222 : null)),
          );

    _carbons = CarbonsManager();
    _pubsub = PubSubManager();
    _bookmarks = BookmarksManager();
    final messageManager = MessageManager();
    // The B track rides along as a stanza extension, and moxxmpp only knows
    // how to serialise the ones it ships with. Without this callback the PQ
    // ciphertext is silently dropped and the stanza leaves in plaintext with
    // the "encrypted, use another client" body - the worst possible outcome:
    // it looks like it worked.
    messageManager.registerMessageSendingCallback(pqSendingCallback);
    await connection.registerManagers([
      PresenceManager(),
      // XEP-0319 idle timestamp on presence (parsed in moxxmpp).
      IdleManager(),
      // Whitespace keepalives (monocles Config.PING_MAX_INTERVAL ≈ 5 min).
      // Without Stream Management this is what notices a half-open TCP.
      PingManager(const Duration(minutes: 5)),
      RosterManager(
        rosterState ??
            (_rosterState = TestingRosterStateManager(null, const [])),
      ),
      // XEP-0077 after login: change password and unregister the account.
      InBandRegistrationManager(),
      DiscoManager(const []),
      _pubsub!,
      // XEP-0402 PEP Native Bookmarks (+ XEP-0048 PEP-conversion fallback).
      _bookmarks!,
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
      // XEP-0172 User Nickname (Conversations NickManager).
      NickManager(),
      // XEP-0054 vCard-temp (MUC room avatars via PHOTO).
      VCardManager(),
      // XEP-0045 group chats.
      MUCManager(),
      // Incoming room invites before MessageManager (empty-bubble prevention).
      _roomInviteManager = RoomInviteManager(),
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
      // XEP-0425: a moderator retracts someone else's group message. The
      // feature is advertised by the room, so this manager does not add it
      // to our own disco.
      MessageModerationManager(),
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

    // RFC 6121: PresenceManager sends initial presence on stream setup.
    // Configure our <show/> before connect so the first broadcast is correct.
    connection
        .getManagerById<PresenceManager>(presenceManager)
        ?.configure(show: _ownShow);
    presence.clear();

    _eventsSub = connection.asBroadcastStream().listen(_onEvent);
    final result = await connection.connect(
      shouldReconnect: reconnect,
      waitUntilLogin: true,
    );
    final ok = result.isType<bool>() && result.get<bool>();
    if (!ok) {
      // The raw object goes to the log, where naming the exact class is what a
      // bug report needs; the UI gets the classified reason instead of a Dart
      // type name.
      final error = result.isType<XmppError>() ? result.get<XmppError>() : null;
      lastFailure = error == null
          ? XmppConnectFailure.unknown
          : classifyConnectFailure(error);
      _log.severe('connect failed: $lastFailure ($error)');
      // A drop before login finishes can leave the failed connection's policy
      // with a reconnect timer armed. Nothing consumes its events any more, and
      // it would reconnect behind the *next* attempt's back. Stop it here.
      await _eventsSub?.cancel();
      _eventsSub = null;
      try {
        await connection.disconnect();
      } catch (e) {
        _log.fine('failed connection teardown: $e');
      }
    }
    _connection = ok ? connection : null;
    _setState(
      ok ? XmppConnectionState.connected : XmppConnectionState.disconnected,
    );
    if (ok) {
      await _afterStreamReady(resumed: false);
      _startLivenessWatchdog();
    }
    _log.info('connect($jid): $ok');
    return ok;
  }

  /// Carbons + PEP after a fresh login or an automatic reconnect.
  ///
  /// moxxmpp reconnects inside the socket without calling [connect] again, so
  /// [StreamNegotiationsDoneEvent] is the only place that re-runs this on a
  /// TCP drop (monocles re-joins MUCs / flushes queue on the same signal).
  Future<void> _afterStreamReady({required bool resumed}) async {
    // Carbons, the MAM disco probe and the own-PEP subscribes do not depend on
    // each other, and the subscribes do not depend on each other. Start all of
    // them before awaiting any: serially this was ~9 round-trips the user paid
    // for on every login before [connect] would even return.
    final carbonsFuture = _enableCarbonsSafely();
    final mamFuture = _isMamAvailable();
    final pepFuture = _subscribeOwnPep();
    _carbonsEnabled = await carbonsFuture;
    _mamAvailable = await mamFuture;
    await pepFuture;
    _log.info(
      'stream ready (resumed=$resumed) carbons=$_carbonsEnabled '
      'mam=$_mamAvailable',
    );
  }

  /// [CarbonsManager.enableCarbons] with the failure kept inside.
  ///
  /// Carbons are an optimisation: a server that refuses the IQ, or a socket
  /// that dies mid-flight, must not turn an already-authenticated login into a
  /// reported failure — which is what letting the exception escape
  /// [_afterStreamReady] did.
  Future<bool> _enableCarbonsSafely() async {
    final carbons = _carbons;
    if (carbons == null) return false;
    try {
      return await carbons.enableCarbons();
    } catch (e) {
      _log.info('could not enable carbons: $e');
      return false;
    }
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
    '$omemoDefactoDevicesNode+notify',
    for (final node in omemoSpecDevicesNodes) ...<String>[node, '$node+notify'],
    // OMEMO2 / monocles — bare node + +notify (PEP_OMEMO2_DEVICE_LIST_NOTIFY).
    omemo2DevicesXmlns,
    '$omemo2DevicesXmlns+notify',
    omemo2BundlesXmlns,
  ];

  /// Subscribes to our own OMEMO device list so the server pushes device
  /// changes to us (which also keeps our peers' lists fresh when they
  /// republish). Peer nodes are subscribed lazily on first use.
  Future<void> _subscribeOwnPep() async {
    final pm = _pubsub;
    final connection = _connection;
    if (pm == null || connection == null) return;
    final bare = connection.connectionSettings.jid.toBare();
    // One IQ per node, all independent: sending them together costs the
    // slowest of the seven instead of the sum.
    await Future.wait([
      for (final node in _subscribedPepNodes) _subscribePepNode(pm, bare, node),
    ]);
  }

  /// Subscribes to one PEP node, logging — never propagating — a refusal.
  ///
  /// A subscription that fails is a missing push notification, not a broken
  /// session, and must not abort the other six.
  Future<void> _subscribePepNode(
    PubSubManager pm,
    JID bare,
    String node,
  ) async {
    try {
      final result = await pm.subscribe(bare, node);
      if (!result.isType<bool>() || !result.get<bool>()) {
        _log.fine('could not subscribe to $node: $result');
      }
    } catch (e) {
      _log.fine('could not subscribe to $node: $e');
    }
  }

  /// Subscribes to a peer's OMEMO device list so we learn about new devices
  /// immediately instead of waiting out the capability TTL.
  Future<void> subscribePeerPep(JID peer) async {
    final pm = _pubsub;
    if (pm == null) return;
    final bare = peer.toBare();
    await Future.wait([
      for (final node in _subscribedPepNodes) _subscribePepNode(pm, bare, node),
    ]);
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

  /// Page size for one MAM query (Conversations `Config.PAGE_SIZE`).
  static const int mamPageSize = 50;

  /// Meta key for the last MAM archive id we have caught up through.
  static const String mamCatchupIdKey = 'mam_catchup_id';

  /// Meta key for the timestamp of the last caught-up archive page.
  static const String mamCatchupTsKey = 'mam_catchup_ts';

  /// Pulls archived messages for one chat (XEP-0313).
  ///
  /// A 1:1 chat queries the account archive with a `with` filter. A room
  /// ([group]) is queried on the room itself, with no `with` field —
  /// Conversations `Query.muc()`. Results are replayed through the normal
  /// inbound pipeline. [beforeId] is an RSM `before` cursor for paging older
  /// history; returns the number of messages the server sent, or null on error.
  Future<int?> fetchHistory(
    JID chatJid, {
    String? beforeId,
    int? pageSize = mamPageSize,
    bool group = false,
  }) async {
    final mm = _connection?.getManagerById<MessageArchiveManagementManager>(
      mamManager,
    );
    final own = _connection?.connectionSettings.jid.toBare();
    if (mm == null || own == null) return null;
    // A room archive is separate from the account archive. Account MAM being
    // off must not block loading a room that advertises MAM itself.
    if (!group && !_mamAvailable) return null;
    final result = await mm.requestMessages(
      group ? chatJid.toBare() : own,
      withJid: group ? null : chatJid.toBare(),
      rsmBefore: beforeId ?? '',
      pageSize: pageSize,
    );
    if (!result.isType<MamQueryResult>()) return null;
    return result.get<MamQueryResult>().count;
  }

  /// One page of messages older than [end] (Conversations `loadMoreMessages`,
  /// [mamPageSize] at a time).
  ///
  /// [beforeId] is the previous page's RSM `<first/>`, used when that page
  /// overlapped messages already on disk. [complete] is the archive's own
  /// flag: true means nothing older matches.
  Future<({int count, bool complete, String? first})?> fetchOlderHistory(
    JID chatJid, {
    required bool group,
    DateTime? end,
    String? beforeId,
  }) async {
    final mm = _connection?.getManagerById<MessageArchiveManagementManager>(
      mamManager,
    );
    final own = _connection?.connectionSettings.jid.toBare();
    if (mm == null || own == null) return null;
    if (!group && !_mamAvailable) return null;
    final cursor = (beforeId != null && beforeId.isNotEmpty) ? beforeId : null;
    final result = await mm.requestMessages(
      group ? chatJid.toBare() : own,
      withJid: group ? null : chatJid.toBare(),
      end: cursor == null
          ? end?.toUtc().subtract(const Duration(milliseconds: 1))
          : null,
      rsmBefore: cursor ?? '',
      pageSize: mamPageSize,
    );
    if (!result.isType<MamQueryResult>()) return null;
    final page = result.get<MamQueryResult>();
    return (count: page.count, complete: page.complete, first: page.first);
  }

  /// Pulls a room archive after join, limited by [HistorySyncSetting].
  ///
  /// Count mode takes the newest N messages. Days mode queries from
  /// now − N days and pages until the archive is done, with no message
  /// ceiling (Gajim). Off does nothing. A private room uses the same
  /// window; there is no unlimited sync.
  Future<void> _catchUpRoomArchive(String roomJid) async {
    final setting = await _loadHistorySync();
    if (setting.mode == HistorySyncMode.off) return;
    final mm = _connection?.getManagerById<MessageArchiveManagementManager>(
      mamManager,
    );
    if (mm == null) return;
    final room = JID.fromString(roomJid).toBare();
    if (setting.mode == HistorySyncMode.days) {
      await _pageMamForward(
        mm: mm,
        archive: room,
        start: DateTime.now().toUtc().subtract(Duration(days: setting.days)),
        mode: HistorySyncMode.days,
      );
      return;
    }
    await _pageMamNewest(mm: mm, archive: room, messageLimit: setting.count);
  }

  /// Catch up the account message archive after login.
  ///
  /// Honours [HistorySyncSetting]: off returns immediately, count stops at
  /// the chosen number, days pages the window until the archive reports
  /// complete. A cursor older than the day window is dropped so a long
  /// absence cannot pull history from before the threshold.
  ///
  /// Receipt requests seen during catch-up are postponed and flushed when the
  /// query finishes (`processPostponed`).
  Future<int?> catchUpHistory({
    String? afterId,
    DateTime? start,
    Future<void> Function(String? archiveId, DateTime? timestamp)? saveCursor,
  }) async {
    final setting = await _loadHistorySync();
    if (setting.mode == HistorySyncMode.off) return 0;

    final mm = _connection?.getManagerById<MessageArchiveManagementManager>(
      mamManager,
    );
    final own = _connection?.connectionSettings.jid.toBare();
    if (mm == null || own == null || !_mamAvailable) return null;

    final now = DateTime.now().toUtc();
    final known = (afterId != null && afterId.isNotEmpty) ? afterId : null;
    _mamCatchingUp = true;
    _pendingReceiptRequests.clear();
    String? lastId = known;
    var total = 0;
    try {
      if (setting.mode == HistorySyncMode.days) {
        final window = Duration(days: setting.days);
        final windowStart = now.subtract(window);
        final raw = start?.toUtc();
        final gapTooWide = raw == null || now.difference(raw) >= window;
        final cursor = (known == null || gapTooWide) ? null : known;
        final pageStart = cursor != null
            ? null
            : (raw != null && !gapTooWide ? raw : windowStart);
        final run = await _pageMamForward(
          mm: mm,
          archive: own,
          start: pageStart,
          afterId: cursor,
          mode: HistorySyncMode.days,
        );
        if (run == null) return null;
        total = run.count;
        lastId = run.lastId ?? lastId;
      } else if (known == null) {
        final run = await _pageMamNewest(
          mm: mm,
          archive: own,
          messageLimit: setting.count,
        );
        if (run == null) return null;
        total = run.count;
        lastId = run.lastId;
      } else {
        final run = await _pageMamForward(
          mm: mm,
          archive: own,
          afterId: known,
          mode: HistorySyncMode.count,
          messageLimit: setting.count,
        );
        if (run == null) return null;
        total = run.count;
        lastId = run.lastId ?? lastId;
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

  /// Pages forward (`after`) until [historySyncShouldContinue] says stop.
  ///
  /// The id returned is the newest archive id seen, so the next login can
  /// resume. Days mode passes no [messageLimit].
  Future<({int count, String? lastId})?> _pageMamForward({
    required MessageArchiveManagementManager mm,
    required JID archive,
    required HistorySyncMode mode,
    DateTime? start,
    String? afterId,
    JID? withJid,
    int? messageLimit,
  }) async {
    var cursor = (afterId != null && afterId.isNotEmpty) ? afterId : null;
    var pageStart = cursor == null ? start : null;
    var total = 0;
    String? lastId = cursor;
    var page = 0;
    while (historySyncShouldContinue(
      mode: mode,
      complete: false,
      fetched: total,
      cursorAdvanced: true,
      messageLimit: messageLimit,
    )) {
      final pageSize = messageLimit == null
          ? mamPageSize
          : min(mamPageSize, messageLimit - total);
      final result = await mm.requestMessages(
        archive,
        withJid: withJid,
        start: pageStart,
        rsmAfter: cursor,
        pageSize: pageSize,
      );
      if (!result.isType<MamQueryResult>()) {
        _log.warning('MAM page $page failed for ${archive.toBare()}');
        return total == 0 ? null : (count: total, lastId: lastId);
      }
      final pageResult = result.get<MamQueryResult>();
      total += pageResult.count;
      if (pageResult.last != null && pageResult.last!.isNotEmpty) {
        lastId = pageResult.last;
      }
      pageStart = null;
      final next = pageResult.last;
      final advanced =
          pageResult.count > 0 &&
          next != null &&
          next.isNotEmpty &&
          next != cursor;
      _log.info(
        'MAM ${archive.toBare()} page $page: ${pageResult.count} msg(s), '
        'complete=${pageResult.complete}, last=$next',
      );
      if (!historySyncShouldContinue(
        mode: mode,
        complete: pageResult.complete,
        fetched: total,
        cursorAdvanced: advanced,
        messageLimit: messageLimit,
      )) {
        break;
      }
      cursor = next;
      page++;
    }
    return (count: total, lastId: lastId);
  }

  /// Newest [messageLimit] messages, one [mamPageSize] page at a time.
  ///
  /// The id returned is the newest archive id (the first page's `<last/>`),
  /// not the oldest page walked to.
  Future<({int count, String? lastId})?> _pageMamNewest({
    required MessageArchiveManagementManager mm,
    required JID archive,
    required int messageLimit,
    JID? withJid,
  }) async {
    var before = '';
    var total = 0;
    String? newestId;
    var page = 0;
    while (historySyncShouldContinue(
      mode: HistorySyncMode.count,
      complete: false,
      fetched: total,
      cursorAdvanced: true,
      messageLimit: messageLimit,
    )) {
      final result = await mm.requestMessages(
        archive,
        withJid: withJid,
        rsmBefore: before,
        pageSize: min(mamPageSize, messageLimit - total),
      );
      if (!result.isType<MamQueryResult>()) {
        _log.warning('MAM page $page failed for ${archive.toBare()}');
        return total == 0 ? null : (count: total, lastId: newestId);
      }
      final pageResult = result.get<MamQueryResult>();
      newestId ??= (pageResult.last != null && pageResult.last!.isNotEmpty)
          ? pageResult.last
          : null;
      total += pageResult.count;
      final next = pageResult.first;
      final advanced =
          pageResult.count > 0 &&
          next != null &&
          next.isNotEmpty &&
          next != before;
      _log.info(
        'MAM ${archive.toBare()} newest page $page: ${pageResult.count} '
        'msg(s), complete=${pageResult.complete}',
      );
      if (!historySyncShouldContinue(
        mode: HistorySyncMode.count,
        complete: pageResult.complete,
        fetched: total,
        cursorAdvanced: advanced,
        messageLimit: messageLimit,
      )) {
        break;
      }
      before = next!;
      page++;
    }
    return (count: total, lastId: newestId);
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
  /// and a `store` hint so the receipt is archived. Gated by
  /// [sendDeliveryReceipts].
  Future<void> sendDeliveryReceipt(JID to, String id) async {
    if (!sendDeliveryReceipts) return;
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
  Future<axolotl.AxolotlOmemoManager> _omemoOrCreate({
    int opkAmount = 20,
  }) async {
    final existing = _omemo;
    if (existing != null) return existing;
    // Several events can race here; building twice would orphan the first
    // device's keys, so the in-flight initialisation is shared.
    return _omemoInit ??= _buildOmemo(opkAmount: opkAmount).whenComplete(() {
      _omemoInit = null;
    });
  }

  Future<axolotl.AxolotlOmemoManager> _buildOmemo({
    required int opkAmount,
  }) async {
    final bareJid = _connection!.connectionSettings.jid.toBare().toString();

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
      // Persist immediately (Conversations stores registration id / identity
      // keys at generation). Waiting for a successful PEP publish would
      // regenerate a new device on every failed announce.
      await deviceStore?.save(device);
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
  ///
  /// Skips fingerprints that are untrusted **or** inactive (monocles
  /// `isTrustedAndActive` on send). Unknown fingerprints are remembered and
  /// blindly trusted until the security page says otherwise (BTBV). A reliable
  /// PEP read also updates local active/inactive bookkeeping.
  Future<List<int>?> _fetchDeviceListDialectAware(String jid) async {
    final resolved =
        await tracks?.resolveOmemoDevices(JID.fromString(jid)) ??
        (devices: const <int>{}, listReadable: false);
    if (!resolved.listReadable) return null;
    final bare = JID.fromString(jid).toBare().toString();
    final trust = fingerprintTrust;
    await trust?.syncAnnouncedDevices(
      jid: bare,
      announcedIds: resolved.devices,
      omemo2: false,
    );
    if (trust == null) return resolved.devices.toList();
    final out = <int>[];
    for (final id in resolved.devices) {
      final fp = await _fingerprintFor(bare, id, omemo2: false);
      if (fp == null) continue;
      if (await trust.mayEncryptToActive(bare, fp)) out.add(id);
    }
    return out;
  }

  /// Cache → PEP bundle → remember. [omemo2] only switches A/B fetch+store.
  Future<String?> _fingerprintFor(
    String bare,
    int deviceId, {
    required bool omemo2,
  }) async {
    final trust = fingerprintTrust;
    final cached = await trust?.fingerprintOfDevice(
      bare,
      deviceId,
      omemo2: omemo2,
    );
    if (cached != null && cached.isNotEmpty) return cached;

    late final String fp;
    if (omemo2) {
      final bundle = await tracks?.getPqBundle(JID.fromString(bare), deviceId);
      if (bundle == null || !bundle.hasPqIdentity) return null;
      fp = hybridOmemo2Fingerprint(
        bundle.ikSerialized,
        Uint8List.fromList(base64Decode(bundle.pqIk)),
      );
    } else {
      final bundle = await tracks?.getOmemoBundle(
        JID.fromString(bare),
        deviceId,
      );
      if (bundle == null) return null;
      fp = bundle.fingerprint;
    }

    await trust?.rememberDevice(
      jid: bare,
      deviceId: deviceId,
      fingerprint: fp,
      omemo2: omemo2,
    );
    return FingerprintTrustStore.normalize(fp);
  }

  /// Peer device fingerprints from local [OmemoIdentities] only (no network).
  Future<List<PeerFingerprintRow>> peerFingerprintRowsLocal(
    String bareJid,
  ) async {
    final bare = JID.fromString(bareJid).toBare().toString();
    return _peerFingerprintRowsFromStore(bare);
  }

  /// Peer fingerprints for the security UI: optional PEP refresh, then local.
  ///
  /// Pass [refreshFromNetwork]: false to paint cached rows immediately; the
  /// security page refreshes in the background afterwards.
  Future<List<PeerFingerprintRow>> peerFingerprintRows(
    String bareJid, {
    bool refreshFromNetwork = true,
  }) async {
    final bare = JID.fromString(bareJid).toBare().toString();
    if (refreshFromNetwork) {
      try {
        await _refreshPeerFingerprintsFromNetwork(bare);
      } catch (_) {
        // Offline / timeout — keep whatever is already stored.
      }
    }
    return _peerFingerprintRowsFromStore(bare);
  }

  Future<void> _refreshPeerFingerprintsFromNetwork(String bare) async {
    final trust = fingerprintTrust;
    final caps = await capabilitiesFor(JID.fromString(bare));
    if (caps == null) return;
    if (caps.classicReliable) {
      await trust?.syncAnnouncedDevices(
        jid: bare,
        announcedIds: caps.peerDevices,
        omemo2: false,
      );
      for (final id in caps.peerDevices) {
        await _fingerprintFor(bare, id, omemo2: false);
      }
    }
    if (caps.pqReliable) {
      await trust?.syncAnnouncedDevices(
        jid: bare,
        announcedIds: caps.pqDevices,
        omemo2: true,
      );
      for (final id in caps.pqDevices) {
        await _fingerprintFor(bare, id, omemo2: true);
      }
    }
  }

  Future<List<PeerFingerprintRow>> _peerFingerprintRowsFromStore(
    String bare,
  ) async {
    final trust = fingerprintTrust;
    if (trust == null) return const [];
    final stored = await trust.identitiesFor(bare);
    final rows = <PeerFingerprintRow>[
      for (final r in stored)
        if (r.fingerprint.isNotEmpty && r.deviceId != 0)
          PeerFingerprintRow(
            peerJid: r.bareJid,
            deviceId: r.deviceId,
            fingerprint: r.fingerprint,
            omemo2: r.omemo2,
            trust: FingerprintTrust.parse(r.trust),
            active: r.active,
          ),
    ];
    rows.sort((a, b) {
      final byActive = (b.active ? 1 : 0).compareTo(a.active ? 1 : 0);
      if (byActive != 0) return byActive;
      final byPeer = a.peerJid.compareTo(b.peerJid);
      if (byPeer != 0) return byPeer;
      final byStack = (a.omemo2 ? 1 : 0).compareTo(b.omemo2 ? 1 : 0);
      if (byStack != 0) return byStack;
      return a.deviceId.compareTo(b.deviceId);
    });
    return rows;
  }

  /// Fingerprints for a MUC: each occupant with a real JID (monocles trusts
  /// per member, not the room address). Always skips [excludeBareJid] / our
  /// own account so "their fingerprints" never lists this installation.
  Future<List<PeerFingerprintRow>> groupFingerprintRows(
    Iterable<String> memberBareJids, {
    String? excludeBareJid,
    bool refreshFromNetwork = true,
  }) async {
    final skip = (excludeBareJid ?? myJid)?.toLowerCase();
    final rows = <PeerFingerprintRow>[];
    final seen = <String>{};
    for (final raw in memberBareJids) {
      final bare = JID.fromString(raw).toBare().toString();
      if (skip != null && bare.toLowerCase() == skip) continue;
      if (!seen.add(bare)) continue;
      rows.addAll(
        await peerFingerprintRows(bare, refreshFromNetwork: refreshFromNetwork),
      );
    }
    return rows;
  }

  /// Other devices on *our* bare JID (carbons recipients), excluding this
  /// installation's classic / OMEMO2 ids — monocles EditAccount own-keys list.
  Future<List<PeerFingerprintRow>> ownOtherDeviceFingerprintRows() async {
    final bare = myJid;
    if (bare == null) return const [];
    final classicId = _omemo == null ? null : await _omemo!.getDeviceId();
    final pqId = bTrack?.device?.id;
    final all = await peerFingerprintRows(bare);
    return [
      for (final r in all)
        if (r.omemo2
            ? (pqId == null || r.deviceId != pqId)
            : (classicId == null || r.deviceId != classicId))
          r,
    ];
  }

  /// Trust snapshot for a stored message on [track] with peer [bareJid].
  Future<EncModeToken> encModeForPeer(String bareJid, Track track) async {
    if (track == Track.none) return EncModeToken.none;
    final trust = await fingerprintTrust?.aggregateActiveTrust(
      JID.fromString(bareJid).toBare().toString(),
      omemo2: track == Track.pq,
    );
    return EncModeToken.of(track, trust: trust);
  }

  /// Set Gajim-style trust for one peer fingerprint.
  Future<void> setPeerFingerprintTrust({
    required String bareJid,
    required String fingerprint,
    required FingerprintTrust trust,
  }) async {
    final store = fingerprintTrust;
    if (store == null) return;
    final bare = JID.fromString(bareJid).toBare().toString();
    await store.setTrust(bare, fingerprint, trust);
    // Refresh the classic encrypt target cache with the new trust filter.
    final om = _omemo;
    if (om != null) {
      final filtered =
          await _fetchDeviceListDialectAware(bare) ?? const <int>[];
      await om.onDeviceListUpdate(bare, filtered);
    }
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
    final bare = JID.fromString(
      _connection!.connectionSettings.jid.toBare().toString(),
    );

    // Local keys must outlive a flaky PEP publish (Conversations keeps the
    // registration id / identity pair in account DB independently of announce).
    await deviceStore?.save(device);

    // Conversations: publishBundlesIfNeeded then publishOwnDeviceIdIfNeeded.
    // Dual-track writes both dialects once each; device list is a per-node
    // merge (own id added). Wiping other devices is only wipeOtherOmemoDevices.
    final published = tracks == null
        ? await _moxxOmemo!
              .publishBundle(bundle)
              .then(
                // moxxmpp's payload bool is
                // `deviceBundlePublish.isType<PubSubError>()` — true means
                // failure.
                (r) => r.isType<bool>() && !r.get<bool>(),
                onError: (_) => false,
              )
        : await tracks!.publishOmemoBundle(bare, bundle);
    if (!published) {
      _log.warning('OMEMO bundle publish reported failure');
    } else {
      await tracks?.notePublishedOmemoDevice(id);
    }
    return id;
  }

  /// Conversations `regenerateKeys` for the **legacy / A-track** stack only.
  ///
  /// When [wipeOther] is true, the classic PEP device list is replaced with
  /// only our new id. OMEMO2 / PQ keys are untouched (use [regenerateOmemo2Keys]).
  Future<int> regenerateOmemoKeys({bool wipeOther = false}) async {
    _omemo = null;
    _omemoInit = null;
    await deviceStore?.clear();
    final id = await ensureOmemoDevice();
    if (wipeOther) {
      await wipeOtherOmemoDevices();
    }
    _capabilities?.invalidateAll();
    return id;
  }

  /// Regenerate the **OMEMO2 / PQ** identity (classical IK + ML-DSA-87).
  Future<bool> regenerateOmemo2Keys({bool wipeOther = false}) async {
    final track = bTrack;
    final bare = _connection?.connectionSettings.jid.toBare().toString();
    if (track == null || bare == null) return false;
    final classicId = omemo == null ? null : await omemo!.getDeviceId();
    final ok = await track.regenerate(
      bareJid: bare,
      classicDeviceId: classicId,
      wipeOther: wipeOther,
    );
    if (ok) _capabilities?.invalidateAll();
    return ok;
  }

  /// Wipe other devices from the **classic OMEMO** PEP announcement only.
  ///
  /// Parallel to [BTrackManager.wipeOtherDevices] on the B stack.
  Future<bool> wipeOtherOmemoDevices() async {
    final manager = await _omemoOrCreate();
    final id = await manager.getDeviceId();
    final bare = JID.fromString(
      _connection!.connectionSettings.jid.toBare().toString(),
    );
    final trackManager = tracks;
    if (trackManager == null) {
      _log.warning('wipeOtherOmemoDevices: dual-track manager not wired');
      return false;
    }
    final ok = await trackManager.publishOmemoDeviceIds(bare, {id});
    if (ok) {
      // Conversations wipeOtherPepDevices leaves only this id on PEP; the
      // local publish history must match or the next merge will treat the
      // wiped ids as still ours and put them back.
      await trackManager.replacePublishedOmemoDevices({id});
      _capabilities?.invalidateAll();
    }
    return ok;
  }

  /// Wipe other devices from the **OMEMO2 / PQ** PEP announcement only
  /// (monocles stack-separate clear).
  Future<bool> wipeOtherOmemo2Devices() async {
    final track = bTrack;
    if (track == null) return false;
    final ok = await track.wipeOtherDevices();
    if (ok) _capabilities?.invalidateAll();
    return ok;
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
    // Same registration id on both stacks (monocles); keys stay separate.
    final classicId = omemo == null ? null : await omemo!.getDeviceId();
    return track.initialise(bare, classicDeviceId: classicId);
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

  /// Encrypts and sends [body] on the PQ track when [to] has at least one
  /// PQ-capable device; otherwise returns null so the caller can fall back.
  ///
  /// Keys go only to PQ devices. Non-PQ handsets of the same account simply
  /// do not receive a copy. If the peer has no PQ devices, or encryption
  /// fails for every PQ device, we return null instead of emitting
  /// unreadable ciphertext (invariant 1).
  Future<String?> sendPqMessage(
    JID to,
    String body, {
    bool requestReceipt = true,
    String? replyTo,
    String? quoteBody,
    ReplyFallback? replyFallback,
    String? originId,
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
    final id = originId ?? _nextStanzaId();

    // monocles generateOmemo2Chat: mutually exclusive with classic axolotl.
    // Without shouldEncrypt:false the OmemoManager re-wraps the fallback body
    // and the peer decrypts to "Use a supported client…" instead of the PQ
    // payload.
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
        if (requestReceipt && sendDeliveryReceipts)
          const MessageDeliveryReceiptData(true),
        // XEP-0333: peers may answer with <displayed/> (Conversations markable).
        if (sendReadReceipts) const MarkableData(true),
        // XEP-0380: declare the track so the receiver can label the message
        // without decrypting it, and so a client that does not know this
        // namespace shows our name rather than guessing.
        const EmeData(Track.pq, name: 'OMEMO-PQ'),
        PqEncryptedData(encrypted),
      ]),
      type: 'chat',
      shouldEncrypt: false,
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
    String? originId,
  }) async {
    final mm = _connection?.getManagerById<MessageManager>(messageManager);
    if (mm == null) throw StateError('not connected');
    final id = originId ?? _nextStanzaId();
    await mm.sendMessage(
      to,
      TypedMap<StanzaHandlerExtension>.fromList([
        MessageBodyData(body),
        MessageIdData(id),
        StableIdData(id, const []),
        if (replyTo != null)
          ReplyData(
            replyTo,
            body: quoteBody,
            start: replyFallback?.start,
            end: replyFallback?.end,
          ),
        if (requestReceipt && sendDeliveryReceipts)
          const MessageDeliveryReceiptData(true),
        if (sendReadReceipts) const MarkableData(true),
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
    String? originId,
  }) async {
    final connection = _connection;
    if (connection == null) throw StateError('not connected');
    final id = originId ?? _nextStanzaId();

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
      // XEP-0184 receipts are 1:1. A private non-anonymous room does take
      // XEP-0333 `<markable/>` so members can answer with `<displayed/>`
      // (Conversations `isPrivateAndNonAnonymous`).
      if (requestReceipt && sendDeliveryReceipts && !isGroup)
        MessageDeliveryReceiptData(true).toXML(),
      if (sendReadReceipts &&
          (!isGroup || (_privateNonAnonymous[to.toBare().toString()] ?? false)))
        const MarkableData(true).toXML(),
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
  /// A room marker is `type='groupchat'` and [messageId] is the room's
  /// stanza-id, not the sender's origin-id.
  Future<void> sendDisplayedMarker(
    JID to,
    String messageId, {
    bool groupchat = false,
  }) async {
    if (!sendReadReceipts) return;
    final mm = _connection?.getManagerById<MessageManager>(messageManager);
    if (mm == null || messageId.isEmpty) return;
    await mm.sendMessage(
      to,
      TypedMap<StanzaHandlerExtension>.fromList([
        ChatMarkerData(ChatMarker.displayed, messageId),
        const MessageProcessingHintData([MessageProcessingHint.store]),
      ]),
      type: groupchat ? 'groupchat' : 'chat',
    );
  }

  var _stanzaCounter = 0;

  /// Locally-unique stanza id. XEP-0184 receipts reference this value.
  String _nextStanzaId() {
    _stanzaCounter++;
    return 'resonchat-${DateTime.now().microsecondsSinceEpoch}-$_stanzaCounter';
  }

  /// Starts (or restarts) the periodic liveness probe.
  ///
  /// Called after a fresh login and after an automatic reconnect: both paths
  /// end with a usable socket, and the old timer must not survive a connection
  /// that was replaced in between.
  void _startLivenessWatchdog() {
    _livenessTimer?.cancel();
    _livenessTimer = Timer.periodic(livenessInterval, (_) {
      unawaited(_runLivenessPing());
    });
    _keepaliveTimer?.cancel();
    _keepaliveTimer = Timer.periodic(keepaliveInterval, (_) {
      if (_state != XmppConnectionState.connected) return;
      _connection?.sendWhitespacePing();
    });
  }

  void _stopLivenessWatchdog() {
    _livenessTimer?.cancel();
    _livenessTimer = null;
    _keepaliveTimer?.cancel();
    _keepaliveTimer = null;
  }

  /// XEP-0199 ping with a deadline; a missing answer forces a reconnect.
  ///
  /// An IQ error is a perfectly good sign of life — it proves the stream is
  /// carrying stanzas in both directions — so only *no reply at all* counts as
  /// dead.
  Future<void> _runLivenessPing() async {
    final connection = _connection;
    if (connection == null || _livenessProbeRunning) return;
    if (_state != XmppConnectionState.connected) return;
    _livenessProbeRunning = true;
    var alive = false;
    try {
      final reply = await connection
          .sendStanza(
            StanzaDetails(
              Stanza.iq(
                to: connection.connectionSettings.serverJid.toString(),
                type: 'get',
                children: [
                  XMLNode(tag: 'ping', attributes: {'xmlns': pingXmlns}),
                ],
              ),
              shouldEncrypt: false,
            ),
          )
          .timeout(livenessTimeout);
      alive = reply != null;
    } catch (e) {
      _log.warning('liveness ping failed: $e');
    } finally {
      _livenessProbeRunning = false;
    }
    // A ping that threw *after* the connection object was replaced belongs to
    // the old socket; do not drag the new one down with it.
    if (alive || !identical(_connection, connection)) return;
    _log.warning('liveness ping timed out; forcing a reconnect');
    // Stop the probe before feeding the failure: the reconnection policy sets
    // the state to notConnected, and a second probe would fire while it waits
    // out its backoff. It is restarted on the next stream-ready event.
    _stopLivenessWatchdog();
    await connection.handleError(TimeoutError());
  }

  Future<void> disconnect() async {
    _stopLivenessWatchdog();
    await _eventsSub?.cancel();
    _eventsSub = null;
    try {
      await _connection?.disconnect();
    } catch (e, st) {
      // moxxmpp's graceful close writes `</stream:stream>` before closing the
      // socket. When the peer has already gone, that write throws
      // `StateError: StreamSink is closed` — an Error, not an Exception, so it
      // escaped the socket wrapper's own guard. Letting it escape here aborted
      // AccountSession.dispose before the database was closed and left the
      // account half torn down.
      _log.warning('disconnect failed (socket already gone): $e', e, st);
    } finally {
      _connection = null;
    }
    presence.clear();
    if (!_presenceChanges.isClosed) _presenceChanges.add(null);
    _setState(XmppConnectionState.disconnected);
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

  /// Last non-empty display roster per lowercased bare room JID.
  final _savedMembers = <String, List<Occupant>>{};

  /// Writes that roster. Set by the account hub; the connection has no database.
  Future<void> Function(GroupChat room)? onRoomRoster;

  /// Whether [roomJid] is Conversations `isPrivateAndNonAnonymous`.
  final _privateNonAnonymous = <String, bool>{};

  /// Disco `muc_nonanonymous`.
  final _nonAnonymous = <String, bool>{};

  /// Show offline affiliation stubs in the member list (JIDs visible to us).
  final _includeOfflineAffiliates = <String, bool>{};

  /// Conversations `participantsCanChangeSubject` from disco roominfo/config.
  final _participantsCanChangeSubject = <String, bool>{};

  /// Conversations `allowInvites` / `membersOnly` / raw allowpm from disco.
  final _allowInvites = <String, bool>{};
  final _membersOnly = <String, bool>{};
  final _allowPmRaw = <String, String?>{};

  /// Room disco advertises XEP-0425 (`urn:xmpp:message-moderate:1`).
  final _roomModeration = <String, bool>{};

  /// Room disco advertises MAM (`urn:xmpp:mam:2`). Keyed by lowercased bare JID.
  final _roomMam = <String, bool>{};

  /// Room disco advertises XEP-0359 (`urn:xmpp:sid:0`). Same key as [_roomMam].
  final _roomStableIds = <String, bool>{};

  Future<void> _publishRoomState(XmppEvent event) async {
    final roomJid = switch (event) {
      MemberJoinedEvent e => e.roomJid,
      MemberChangedEvent e => e.roomJid,
      MemberLeftEvent e => e.roomJid,
      MemberChangedNickEvent e => e.roomJid,
      OwnDataChangedEvent e => e.roomJid,
      RoomSubjectChangedEvent e => e.roomJid,
      _ => null,
    };
    if (roomJid == null) return;
    final bare = roomJid.toBare().toString();
    if (event is OwnDataChangedEvent) {
      await _reconsiderOfflineAffiliates(bare, event.affiliation.value);
    }
    await _emitRoomState(bare);
  }

  /// Owner/admin promotion can unlock JIDs + affiliation list mid-session.
  Future<void> _reconsiderOfflineAffiliates(
    String bare,
    String selfAffiliation,
  ) async {
    final nonAnonymous = _nonAnonymous[bare] ?? false;
    final includeOffline = canSeeRoomMemberJids(
      nonAnonymous: nonAnonymous,
      selfAffiliation: selfAffiliation,
    );
    final was = _includeOfflineAffiliates[bare] ?? false;
    _includeOfflineAffiliates[bare] = includeOffline;
    if (includeOffline && !was) {
      await fetchRoomAffiliations(bare);
    } else if (!includeOffline && was) {
      _affiliations.remove(bare);
    }
  }

  /// Emit display roster via [resolveRoomRoster] (local-first), then optionally
  /// persist a usable live merge.
  Future<void> _emitRoomState(String roomJid) async {
    final bare = JID.fromString(roomJid).toBare().toString();
    final state = await groupChatState(bare);
    if (state == null || _roomOccupants.isClosed) return;
    final online = state.members.values.map(Occupant.from).toList();
    final live = roomMembersForDisplay(
      includeOfflineAffiliates: _includeOfflineAffiliates[bare] ?? false,
      affiliation: _affiliations[bare] ?? const [],
      online: online,
    );
    final saved = savedRoomMembers(bare);
    final occupants = resolveRoomRoster(live: live, saved: saved);
    final chat = GroupChat(
      roomJid: bare,
      // A room with no nick is one we are not in; showing the member list of
      // a room we only queried would be a list of people we are not talking
      // to.
      nick: state.nick ?? '',
      occupants: occupants,
      subject: state.subject,
      joined: state.joined,
      canSeeMemberJids:
          (_includeOfflineAffiliates[bare] ?? false) ||
          roomRosterHasRealJids(occupants),
    );
    _roomOccupants.add(chat);
    if (!shouldPersistRoomRoster(live: live, saved: saved)) return;
    _savedMembers[_roomKey(bare)] = live;
    final persist = onRoomRoster;
    if (persist != null) {
      unawaited(persist(chat.copyWith(occupants: live)));
    }
  }

  /// Disco `muc_membersonly` for [roomJid]. False until that disco result lands.
  bool isMembersOnly(String roomJid) {
    final bare = JID.fromString(roomJid).toBare().toString();
    return _membersOnly[bare] ?? false;
  }

  /// Whether the member list for [roomJid] includes offline affiliates.
  bool roomCanSeeMemberJids(String roomJid) {
    final bare = JID.fromString(roomJid).toBare().toString();
    return _includeOfflineAffiliates[bare] ?? false;
  }

  void _onEvent(XmppEvent event) {
    if (event is ConnectionStateChangedEvent) {
      // moxxmpp's XmppConnectionState is shadowed by ours; use .name.
      final next = switch (event.state.name) {
        'connected' => XmppConnectionState.connected,
        'connecting' => XmppConnectionState.connecting,
        _ => XmppConnectionState.disconnected,
      };
      _setState(next);
      // The watchdog belongs to one live socket. A drop, or the reconnect's
      // own "connecting" interlude, must not leave a timer behind that probes
      // a stream that is no longer there.
      if (next != XmppConnectionState.connected) _stopLivenessWatchdog();
      return;
    }
    if (event is StreamNegotiationsDoneEvent) {
      // Automatic reconnect path: [connect] is not re-entered, so carbons /
      // PEP must be re-armed here (monocles manageAccountConnectionStates).
      if (_connection != null) {
        unawaited(_afterStreamReady(resumed: event.resumed));
        _startLivenessWatchdog();
      }
      return;
    }
    if (event is StanzaSendingCancelledEvent) {
      // A pre-send handler refused to encrypt the stanza: nothing left the
      // client. MessageManager.sendMessage is unawaitable, so without this
      // the send path reports success and the bubble keeps a tick for a
      // message no device ever received.
      final stanza = event.data.stanza;
      final id = stanza.id;
      final to = stanza.to;
      if (stanza.tag == 'message' &&
          id != null &&
          id.isNotEmpty &&
          to != null) {
        if (!_deliveryFailures.isClosed) {
          _deliveryFailures.add(
            DeliveryFailure(
              stanzaId: id,
              from: JID.fromString(to),
              reason: describeSendingCancellation(event.data.cancelReason),
            ),
          );
        }
      }
      return;
    }
    if (event is MessageEvent) {
      final error = event.encryptionError;
      // Our own message coming back as an error: it was refused, not
      // delivered. Report it so the UI can correct the stored row instead of
      // leaving a bubble that looks sent.
      final stanzaError = event.error;
      if (stanzaError != null) {
        // A bounce is never inbound content: the server echoes the stanza we
        // sent and stamps the peer as `from`. Chat states, receipts and
        // markers come back the same way, so processing one as an incoming
        // message makes our own `composing` look like the peer typing.
        if (event.id != null &&
            event.id!.isNotEmpty &&
            carriesMessageContent(event)) {
          if (!_deliveryFailures.isClosed) {
            _deliveryFailures.add(
              DeliveryFailure(
                stanzaId: event.id!,
                from: event.from,
                reason: describeStanzaError(stanzaError),
              ),
            );
          }
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

      final hasContent = messageEventHasContent(event);
      // Chat-state-only stanzas are not stored (Conversations treats them as
      // presence-like notifications).
      if (chatState != null && !hasContent) {
        return;
      }

      // XEP-0184: answer `<request/>` like Conversations DeliveryReceiptManager.
      // Live → send immediately; catch-up → postpone until processPostponed.
      final receiptRequested =
          event.get<MessageDeliveryReceiptData>()?.receiptRequested ?? false;
      if (sendDeliveryReceipts &&
          receiptRequested &&
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

      final inbound = inboundFromMessageEvent(
        event,
        roomStableIds: _roomStableIds,
      );
      if (inbound == null) return;
      _inbound.add(inbound);
      if (inbound.reactions != null) _reactions.add(inbound);
    } else if (event is ChatMarkerEvent) {
      // XEP-0333: <received/> is delivery; <displayed/> is read
      // (Conversations DisplayedManager / delivery path).
      if (event.type == ChatMarker.displayed) {
        if (!_readReceipts.isClosed) {
          _readReceipts.add(ReadReceipt(from: event.from, stanzaId: event.id));
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
    } else if (event is BookmarksUpdatedEvent) {
      if (!_bookmarksChanges.isClosed) _bookmarksChanges.add(null);
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
    } else if (event is PresenceReceivedEvent) {
      // MUC occupant presence is consumed by MUCManager (higher priority).
      // What reaches here is roster / 1:1 availability (RFC 6121 §4).
      presence.apply(
        event.data,
        idleSince: event.data.available ? event.get<IdleData>()?.since : null,
      );
      if (!_presenceChanges.isClosed) _presenceChanges.add(null);
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
      _pendingIncoming.add(JID.fromString('${event.from}').toBare().toString());
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
  Set<String> get pendingIncomingRequests => Set.unmodifiable(_pendingIncoming);
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

/// Whether a bounced stanza was a message the user actually sent.
///
/// A server echoes the refused stanza verbatim and adds `<error/>`. Chat
/// states, receipts and markers therefore come back looking like ordinary
/// inbound traffic; only a body (or an encrypted payload) marks the stanza as
/// a message whose delivery the user cares about.
bool carriesMessageContent(MessageEvent event) =>
    event.encrypted ||
    event.encryptionError != null ||
    (event.get<MessageBodyData>()?.body ?? '').isNotEmpty;

/// Renders why a pre-send handler cancelled a stanza.
///
/// The interesting case is OMEMO giving up because no recipient device had
/// usable key material — that is not a transport failure and must not be
/// retried as one, but the user still needs to know the message did not go.
String describeSendingCancellation(Object? reason) {
  if (reason is OmemoNotSupportedForContactException) {
    return 'cancel/omemo: this contact has no usable encryption device';
  }
  if (reason is OmemoError) {
    return 'cancel/omemo: the message could not be encrypted';
  }
  return 'cancel: sending was cancelled before the stanza left the client';
}
