// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// View model for the chat page: UI state plus the domain logic that used to
// live in `_ChatPageState`. Everything that needs a `BuildContext` (dialogs,
// snackbars, navigation, pickers) stays in the page; this class reports
// outcomes and the page decides how to show them.

import 'dart:async';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import 'package:moxxmpp/moxxmpp.dart' show JID;

import 'package:resonchat/account/resolve.dart';
import 'package:resonchat/crypto/dual/track.dart';
import 'package:resonchat/crypto/dual/track_advice.dart';
import 'package:resonchat/crypto/dual/track_resolver.dart';
import 'package:resonchat/domain/messages_service.dart';
import 'package:resonchat/l10n/generated/app_localizations.dart';
import 'package:resonchat/persistence/database.dart';
import 'package:resonchat/state/app_wiring.dart';
import 'package:resonchat/state/providers.dart';
import 'package:resonchat/xmpp/chat/forwarding.dart';
import 'package:resonchat/xmpp/chat/reactions.dart';
import 'package:resonchat/xmpp/chat/replies.dart';
import 'package:resonchat/xmpp/chat/retraction.dart' as retraction;
import 'package:resonchat/xmpp/chat/sticker_link.dart';
import 'package:resonchat/xmpp/connection.dart';
import 'package:resonchat/xmpp/conversation_archive.dart';
import 'package:resonchat/xmpp/message_send_status.dart';
import 'package:resonchat/xmpp/muc/muc.dart';

/// Asks the user whether to send in the clear. Implemented by the page with
/// `confirmPlaintext` from track_dialogs.dart.
typedef ConfirmPlaintextFn = Future<bool> Function({
  required String contact,
  required Track alternative,
});

/// Asks the user which track to use instead of one that cannot be used.
/// Implemented by the page with `askTrackSubstitute` from track_dialogs.dart.
typedef AskTrackSubstituteFn = Future<Track?> Function({
  required TrackBlocked blocked,
  required Track alternative,
});

/// The user-facing questions [ChatViewModel.resolveTrackForSend] may need
/// answered. The page implements them (and must answer "no" once it is gone).
class ChatTrackConfirm {
  const ChatTrackConfirm({
    required this.confirmPlaintext,
    required this.askTrackSubstitute,
  });

  final ConfirmPlaintextFn confirmPlaintext;
  final AskTrackSubstituteFn askTrackSubstitute;
}

/// The message being replied to: its id, its text, and who wrote it.
typedef ChatReplyTarget = ({String id, String body, String author});

/// What [ChatViewModel.sendText] did.
class ChatSendResult {
  const ChatSendResult({this.outcome, this.failureReason, this.queued = false});

  /// The send outcome, or null when nothing was attempted / the user
  /// cancelled.
  final SendOutcome? outcome;

  /// Set when the send was attempted and refused (page: "Not sent: …").
  final String? failureReason;

  /// True once the row is in the local DB (Conversations insert-first).
  ///
  /// The page clears the composer on [queued], even when the socket write
  /// later fails — the bubble stays with [MessageSendStatus.sendFailed].
  final bool queued;

  bool get sent => outcome?.sent ?? false;
}

/// What [ChatViewModel.sendAttachmentBytes] did.
class ChatAttachResult {
  const ChatAttachResult({
    this.sent = false,
    this.queued = false,
    this.failureReason,
    this.error,
    this.uploadUnavailable = false,
  });

  final bool sent;

  /// True once the attachment row is in the local DB.
  final bool queued;

  /// Set when the message was refused after upload (page: "Not sent: …").
  final String? failureReason;

  /// Set when upload or send threw.
  final String? error;

  /// The server has no XEP-0363 slot, and this sticker still needs an upload.
  final bool uploadUnavailable;
}

/// What [ChatViewModel.forwardToChat] did.
class ChatForwardResult {
  const ChatForwardResult({
    required this.destPeer,
    this.blocked = false,
    this.outcome,
  });

  final String destPeer;

  /// The destination is blocked; nothing was sent.
  final bool blocked;

  /// Null when blocked or when the view model was disposed before sending.
  final ForwardOutcome? outcome;
}

/// What [ChatViewModel.deleteMineByIds] did.
typedef ChatDeleteResult = ({int mine, int deleted});

/// Navigation the page should do after [ChatViewModel.applyMemberResult].
enum ChatMemberEffectKind {
  left,
  openChat,
  privateMessage,
  destroyFailed,
  none,
}

class ChatMemberEffect {
  const ChatMemberEffect(this.kind, {this.jid});

  final ChatMemberEffectKind kind;

  /// Peer JID to open for [ChatMemberEffectKind.openChat].
  final String? jid;
}

const Object _keep = Object();

/// Immutable UI state of one chat.
class ChatUiState {
  const ChatUiState({
    this.isGroup = false,
    this.mucNick = '',
    this.mucEncryptable = false,
    this.canChangeSubject = false,
    this.canModerate = false,
    this.room,
    this.roomJid,
    this.mucPmNick,
    this.peerTyping = TypingState.inactive,
    this.advice,
    this.sending = false,
    this.pickingFile = false,
  });

  /// Conversations MODE_MULTI — from the chat row, never from parsing the JID.
  final bool isGroup;
  final String mucNick;

  /// Conversations `isPrivateAndNonAnonymous` — OMEMO allowed only then.
  final bool mucEncryptable;

  /// Conversations `MucOptions.canChangeSubject`.
  final bool canChangeSubject;

  /// Moderator in a room that advertises XEP-0425.
  final bool canModerate;

  /// The group chat being shown, or null for 1:1 / not loaded yet.
  final GroupChat? room;
  final String? roomJid;

  /// Conversations `nextCounterpart` nick for in-room private messages.
  final String? mucPmNick;

  /// Peer chat state (Conversations ChatStateManager.incoming).
  final TypingState peerTyping;

  /// Most recent advice about *this* conversation, or null.
  final TrackAdvice? advice;

  /// Guards against a double tap sending twice while the first send awaits.
  final bool sending;

  /// True while the system file picker is open — freezes the chat behind it.
  final bool pickingFile;

  /// Nullable fields ([room], [roomJid], [mucPmNick], [advice]) are replaced
  /// by whatever is passed, including an explicit `null`; omit to keep.
  ChatUiState copyWith({
    bool? isGroup,
    String? mucNick,
    bool? mucEncryptable,
    bool? canChangeSubject,
    bool? canModerate,
    Object? room = _keep,
    Object? roomJid = _keep,
    Object? mucPmNick = _keep,
    TypingState? peerTyping,
    Object? advice = _keep,
    bool? sending,
    bool? pickingFile,
  }) {
    return ChatUiState(
      isGroup: isGroup ?? this.isGroup,
      mucNick: mucNick ?? this.mucNick,
      mucEncryptable: mucEncryptable ?? this.mucEncryptable,
      canChangeSubject: canChangeSubject ?? this.canChangeSubject,
      canModerate: canModerate ?? this.canModerate,
      room: identical(room, _keep) ? this.room : room as GroupChat?,
      roomJid: identical(roomJid, _keep) ? this.roomJid : roomJid as String?,
      mucPmNick: identical(mucPmNick, _keep)
          ? this.mucPmNick
          : mucPmNick as String?,
      peerTyping: peerTyping ?? this.peerTyping,
      advice: identical(advice, _keep) ? this.advice : advice as TrackAdvice?,
      sending: sending ?? this.sending,
      pickingFile: pickingFile ?? this.pickingFile,
    );
  }
}

/// One view model per chat ([ChatRef.key] or legacy bare JID).
///
/// Auto-disposed: its subscriptions (inbound displayed markers, delivery
/// failures, typing, …) mean "this chat is open", so they must not outlive the
/// page that watches it.
final chatViewModelProvider = NotifierProvider.autoDispose
    .family<ChatViewModel, ChatUiState, String>(ChatViewModel.new);

class ChatViewModel extends AutoDisposeFamilyNotifier<ChatUiState, String> {
  final _log = Logger('ChatViewModel');

  bool _disposed = false;

  /// True while we have announced `composing` and not yet `paused`/`active`
  /// (Conversations EditMessage.isUserTyping).
  bool _typingNotified = false;

  /// Clears composing → paused after Config.TYPING_TIMEOUT (8s).
  Timer? _typingTimeout;

  StreamSubscription<DeliveryFailure>? _failureSub;
  StreamSubscription<TypingNotification>? _typingSub;
  StreamSubscription<InboundMessage>? _inboundReadSub;
  StreamSubscription<GroupChat?>? _roomSub;
  StreamSubscription<TrackAdvice>? _adviceSub;

  final _failureCtl = StreamController<String>.broadcast();
  final _noticeCtl = StreamController<String>.broadcast();

  /// Conversations TYPING_TIMEOUT — seconds of idle before `paused`.
  static const int _typingTimeoutSecs = 8;

  /// The [ChatRef.key] (accountId + peer JID), or legacy bare JID.
  String get chatKey => arg;

  /// Peer bare JID for XMPP (not the opaque chat key).
  String get peerJid => resolveChatKey(arg).jid;

  XmppService get _xmpp => resolveChatKey(arg).session.xmpp;

  AppDatabase get _db => resolveChatKey(arg).session.db;

  /// Reasons for messages the server refused in *this* conversation, after the
  /// stored row was marked. The page shows the snackbar.
  Stream<String> get failureNotices => _failureCtl.stream;

  /// Plain notices the page should surface (e.g. a MUC join error).
  Stream<String> get notices => _noticeCtl.stream;

  @override
  ChatUiState build(String chatKey) {
    _disposed = false;
    final r = resolveChatKey(chatKey);
    final xmpp = r.session.xmpp;
    final peer = r.jid;

    // A message the server refused must stop looking sent.
    _failureSub = xmpp.deliveryFailures.listen((f) async {
      final reason = await handleDeliveryFailure(f);
      if (reason != null && !_disposed) _failureCtl.add(reason);
    });
    _adviceSub = trackAdvice.listen(onAdvice);
    _typingSub = xmpp.typingStates.listen(onPeerTyping);
    // While this chat is open, a new inbound markable message is already
    // being read — send <displayed/> like Conversations markRead on open.
    _inboundReadSub = xmpp.inbound.listen((msg) {
      if (msg.from.toBare().toString() != peer) return;
      if (!msg.markable || msg.fromArchive) return;
      final id = msg.originId ?? msg.stanzaId;
      if (id == null || id.isEmpty) return;
      unawaited(xmpp.sendDisplayedMarker(JID.fromString(peer), id));
    });
    // Deliberately *not* marked read here: marking on arrival would clear the
    // unread badge before the user has read anything. The page marks read when
    // it goes away.

    ref.onDispose(() {
      _disposed = true;
      _typingTimeout?.cancel();
      _failureSub?.cancel();
      _adviceSub?.cancel();
      _typingSub?.cancel();
      _inboundReadSub?.cancel();
      _roomSub?.cancel();
      _failureCtl.close();
      _noticeCtl.close();
    });

    unawaited(bootstrapRoom());
    return const ChatUiState();
  }

  void _set(ChatUiState Function(ChatUiState s) f) {
    if (_disposed) return;
    state = f(state);
  }

  // --- Draft / track persistence (WidgetRef helpers cannot be used here) ----

  /// Records or clears the draft for this chat.
  Future<void> saveDraft(String? text) async {
    final r = resolveChatKey(arg);
    final bump = ref.read(draftRevisionProvider.notifier);
    await r.session.db.setDraft(r.jid, text);
    bump.state = bump.state + 1;
  }

  // --- Room (MODE_MULTI) ----------------------------------------------------

  /// Loads MODE_MULTI state from the chat row (bare room JID + nick).
  Future<void> bootstrapRoom() async {
    final r = resolveChatKey(arg);
    // Conversations findOrCreateConversation → restoreFromArchive on open.
    var row = await r.session.db.getChat(r.jid);
    if (row != null && row.archived) {
      await restoreFromArchive(arg);
      if (_disposed) return;
      row = await r.session.db.getChat(r.jid);
    }
    if (_disposed || row == null || !row.isGroup) return;
    state = state.copyWith(
      isGroup: true,
      mucNick: row.mucNick,
      mucEncryptable: row.mucPrivateNonAnonymous,
      roomJid: r.jid,
    );
    // Local roster first (same resolveRoomRoster path as members UI).
    final local = r.session.xmpp.localRoomChat(r.jid, nick: row.mucNick);
    if (local != null) {
      state = state.copyWith(room: local);
    }
    await _roomSub?.cancel();
    // Stream already emits resolveRoomRoster results — apply as-is.
    _roomSub = r.session.xmpp.roomOccupants(r.jid).listen((chat) {
      if (_disposed || chat == null) return;
      state = state.copyWith(room: chat);
      unawaited(refreshCanChangeSubject());
      unawaited(refreshCanModerate());
    });
    // Network catch-up after local paint — do not block open on disco/join.
    unawaited(() async {
      await loadRoom();
      await refreshRoomEncryptable();
    }());
  }

  Future<void> refreshCanChangeSubject() async {
    final jid = state.roomJid;
    if (jid == null) return;
    final can = await _xmpp.canChangeSubject(jid);
    if (_disposed || can == state.canChangeSubject) return;
    state = state.copyWith(canChangeSubject: can);
  }

  /// Moderator role plus the room advertising XEP-0425.
  Future<void> refreshCanModerate() async {
    final jid = state.roomJid;
    if (jid == null || !state.isGroup) return;
    final can = await _xmpp.canModerate(jid);
    if (_disposed || can == state.canModerate) return;
    state = state.copyWith(canModerate: can);
  }

  /// Re-query disco so OMEMO availability matches Conversations after join.
  Future<void> refreshRoomEncryptable() async {
    final jid = state.roomJid;
    if (jid == null) return;
    final xmpp = _xmpp;
    final info = await xmpp.queryRoomInformation(jid);
    final features = info?.features ?? const <String>[];
    final encryptable = isPrivateAndNonAnonymous(features);
    final nonAnonymous = isNonAnonymousRoom(features);
    await xmpp.refreshRoomMembership(
      jid,
      privateNonAnonymous: encryptable,
      nonAnonymous: nonAnonymous,
    );
    final discoName = info?.name.trim();
    final titleUpdate = await _roomTitleFromDisco(jid, discoName);
    await _db.upsertChat(
      jid,
      title: titleUpdate,
      isGroup: true,
      mucPrivateNonAnonymous: encryptable,
    );
    if (_disposed) return;
    if (titleUpdate != null) {
      ref.invalidate(chatProvider(arg));
      ref.read(chatRowRevisionProvider.notifier).state++;
    }
    if (encryptable != state.mucEncryptable) {
      state = state.copyWith(mucEncryptable: encryptable);
    }
    // Affiliation fetch may have added offline members — reload the list.
    ref.invalidate(roomStateProvider(arg));
    final chat = await ref.read(roomStateProvider(arg).future);
    if (_disposed || chat == null) return;
    state = state.copyWith(room: chat);
    await refreshCanChangeSubject();
    await refreshCanModerate();
  }

  /// Disco / bookmark name when the stored title is still a JID placeholder.
  Future<String?> _roomTitleFromDisco(String jid, String? discoName) async {
    final name = discoName?.trim() ?? '';
    if (name.isEmpty) return null;
    final row = await _db.getChat(jid);
    final current = row?.title.trim() ?? '';
    final at = jid.indexOf('@');
    final local = at > 0 ? jid.substring(0, at) : jid;
    final placeholder = current.isEmpty || current == jid || current == local;
    if (!placeholder) return null;
    if (current == name) return null;
    return name;
  }

  Future<void> loadRoom() async {
    final jid = state.roomJid;
    if (jid == null) return;
    var nick = state.mucNick;
    if (nick.isEmpty) {
      final row = await _db.getChat(jid);
      nick = row?.mucNick ?? '';
      if (nick.isNotEmpty && !_disposed) {
        state = state.copyWith(mucNick: nick);
      }
    }
    if (_disposed) return;
    var chat = await ref.read(roomStateProvider(arg).future);
    // Join with the stored nick when the MUC cache has nothing yet
    // (Conversations joinMuc on open / connect).
    if ((chat == null || !chat.joined) && nick.isNotEmpty) {
      final err = await _xmpp.joinGroupChat(jid, nick);
      if (_disposed) return;
      if (err != null) _noticeCtl.add('$err');
      ref.invalidate(roomStateProvider(arg));
      chat = await ref.read(roomStateProvider(arg).future);
    }
    if (_disposed || chat == null) return;
    state = state.copyWith(room: chat);
  }

  /// Leaves [roomJid] and clears the nick so connect does not auto-rejoin
  /// until the user joins again. Navigation stays in the page.
  Future<void> leaveRoom(String roomJid) async {
    await _xmpp.leaveGroupChat(roomJid);
    // Keep isGroup; clear nick. Retract the PEP bookmark so other devices
    // (and the next login) do not auto-rejoin a room we just left.
    await _db.upsertChat(roomJid, isGroup: true, mucNick: '');
    await _xmpp.retractConferenceBookmark(roomJid);
  }

  /// Conversations `destroyRoom`: tear down on the server, then drop local chat.
  ///
  /// Returns false when the IQ failed (room stays).
  Future<bool> destroyRoom(String roomJid) async {
    final ok = await _xmpp.destroyRoom(roomJid);
    if (!ok) return false;
    await _db.deleteChat(roomJid);
    return true;
  }

  /// Applies the side effects of a [RoomProfilePage] result and says what the
  /// page should do next. Mirrors Conversations startConversation /
  /// privateMessageWith / nextCounterpart.
  Future<ChatMemberEffect> applyMemberResult({
    required String roomJid,
    required bool leaving,
    bool destroyed = false,
    String? jid,
    String? mucPmNick,
  }) async {
    if (destroyed) {
      final ok = await destroyRoom(roomJid);
      if (!ok) {
        return const ChatMemberEffect(ChatMemberEffectKind.destroyFailed);
      }
      return const ChatMemberEffect(ChatMemberEffectKind.left);
    }
    if (leaving) {
      await leaveRoom(roomJid);
      return const ChatMemberEffect(ChatMemberEffectKind.left);
    }
    // Non-anonymous → bare JID 1:1.
    if (jid != null && jid.isNotEmpty) {
      await _db.upsertChat(jid, isGroup: false);
      return ChatMemberEffect(ChatMemberEffectKind.openChat, jid: jid);
    }
    // Stay in room UI, but address the next message privately.
    if (mucPmNick != null && mucPmNick.isNotEmpty) {
      setMucPmNick(mucPmNick);
      return const ChatMemberEffect(ChatMemberEffectKind.privateMessage);
    }
    return const ChatMemberEffect(ChatMemberEffectKind.none);
  }

  /// Sets or clears the in-room private-message counterpart.
  void setMucPmNick(String? nick) => _set((s) => s.copyWith(mucPmNick: nick));

  // --- Read markers / chat states ------------------------------------------

  /// Sends XEP-0333 displayed for the newest inbound message we can mark.
  ///
  /// A private non-anonymous room uses the room stanza-id (Conversations
  /// `DisplayedManager.displayedMessage`). Other rooms send nothing. 1:1 uses
  /// the origin id of the newest markable message.
  Future<void> sendDisplayedForLatest() async {
    final r = resolveChatKey(arg);
    final chat = await r.session.db.getChat(r.jid);
    if (chat?.isGroup == true) {
      if (chat?.mucPrivateNonAnonymous != true) return;
      final last = await r.session.db.lastIncomingWithRoomStanza(r.jid);
      final id = last?.roomStanzaId ?? '';
      if (id.isEmpty) return;
      await r.session.xmpp.sendDisplayedMarker(
        JID.fromString(r.jid),
        id,
        groupchat: true,
      );
      return;
    }
    final last = await r.session.db.lastIncomingMarkable(r.jid);
    if (last == null || last.stanzaId.isEmpty) return;
    await r.session.xmpp.sendDisplayedMarker(
      JID.fromString(r.jid),
      last.stanzaId,
    );
  }

  /// Marks the chat read locally and sends XEP-0333 `<displayed/>`
  /// (Conversations `markRead` → `DisplayedManager.displayed`).
  ///
  /// Safe to call as the page goes away: everything that needs `ref` is read
  /// before the first await.
  Future<void> markReadAndSendDisplayed() async {
    final r = resolveChatKey(arg);
    final bump = ref.read(chatRowRevisionProvider.notifier);
    // Capture before any await: dispose fires this without awaiting, and a
    // message can arrive before markChatRead runs. The marker must be "left
    // at", not "SQL finished at", or that message is wiped from the badges.
    final leftAt = DateTime.now();
    await r.session.db.markChatRead(r.jid, at: leftAt);
    bump.state = bump.state + 1;
    await sendDisplayedForLatest();
  }

  void onPeerTyping(TypingNotification n) {
    if (n.from.toBare().toString() != peerJid) return;
    if (_disposed) return;
    if (n.state == state.peerTyping) return;
    state = state.copyWith(peerTyping: n.state);
  }

  /// Publishes leave chat state (Conversations `updateChatState`): paused if a
  /// draft remains, else active.
  Future<void> publishComposerChatState({required bool composerEmpty}) async {
    _typingTimeout?.cancel();
    final r = resolveChatKey(arg);
    _typingNotified = false;
    await r.session.xmpp.sendChatState(
      JID.fromString(r.jid),
      composerEmpty ? TypingState.inactive : TypingState.paused,
    );
  }

  /// Draft saved on every keystroke (the app can be killed or the chat
  /// switched from a notification, neither of which gives a callback), then
  /// the XEP-0085 part.
  void onInputChanged(String value) {
    unawaited(saveDraft(value));
    notifyTypingOnInput(value);
  }

  /// XEP-0085 send path aligned with Conversations EditMessage:
  /// composing on first non-empty keystroke, paused after idle timeout,
  /// active when the box is cleared.
  void notifyTypingOnInput(String value) {
    // Groupchat chat-states are not the 1:1 typing model.
    if (state.isGroup) return;

    _typingTimeout?.cancel();
    final length = value.trim().length;
    final xmpp = _xmpp;
    final peer = JID.fromString(peerJid);

    if (length == 0) {
      // onTextDeleted → DEFAULT_CHAT_STATE (active).
      _typingNotified = false;
      unawaited(xmpp.sendChatState(peer, TypingState.inactive));
      return;
    }

    _typingTimeout = Timer(const Duration(seconds: _typingTimeoutSecs), () {
      if (!_typingNotified) return;
      // onTypingStopped → paused; next keystroke re-sends composing.
      _typingNotified = false;
      unawaited(xmpp.sendChatState(peer, TypingState.paused));
    });

    if (!_typingNotified) {
      _typingNotified = true;
      unawaited(xmpp.sendChatState(peer, TypingState.composing));
    }
  }

  /// The page put a stored draft back into the composer.
  void onDraftRestored(String draft) {
    _typingNotified = draft.trim().isNotEmpty;
  }

  /// The composer was emptied by a successful send: drop the draft and tell
  /// the peer we are no longer composing.
  void onMessageSent() {
    _typingTimeout?.cancel();
    unawaited(saveDraft(null));
    _typingNotified = false;
    if (!state.isGroup) {
      unawaited(
        _xmpp.sendChatState(JID.fromString(peerJid), TypingState.inactive),
      );
    }
  }

  // --- Delivery failure -----------------------------------------------------

  /// Marks the refused message in the DB. Returns the reason to show, or null
  /// when the failure is about another conversation or not a stored message.
  ///
  /// Servers bounce body-less stanzas too — chat states, receipts, markers —
  /// and the updater is the test for "this was one of our messages": no row
  /// means nothing to mark and nothing to report.
  Future<String?> handleDeliveryFailure(DeliveryFailure failure) async {
    if (failure.from.toBare().toString() != peerJid) return null;
    final recorded = await _db.markDeliveryFailure(
      failure.stanzaId,
      failure.reason,
    );
    return recorded ? failure.reason : null;
  }

  // --- Track advice ---------------------------------------------------------

  /// Advice names the conversation it is about; advice about other
  /// conversations is dropped rather than stored.
  void onAdvice(TrackAdvice advice) {
    if (advice.chatJid != peerJid) return;
    if (_disposed) return;
    state = state.copyWith(advice: advice);
  }

  void dismissAdvice() {
    if (state.advice == null) return;
    state = state.copyWith(advice: null);
  }

  void adoptAdvice() {
    final advice = state.advice;
    if (advice == null) return;
    state = state.copyWith(advice: null);
    unawaited(_setChatTrack(advice.suggestion));
  }

  /// Pins this chat to [track], or clears the override when null.
  /// (`setChatTrack` in providers.dart needs a `WidgetRef`.)
  Future<void> _setChatTrack(Track? track) async {
    final r = resolveChatKey(arg);
    await r.session.db.setTrackOverride(r.jid, track);
    await r.session.db.clearPlaintextAcknowledgement(r.jid);
    if (_disposed) return;
    ref.invalidate(chatTrackOverrideProvider(arg));
    ref.invalidate(chatTrackProvider(arg));
  }

  // --- Sending --------------------------------------------------------------

  /// Track resolution / plaintext confirm — shared by 1:1 and MUC.
  ///
  /// When the chosen track cannot be used, asks via [confirm] (e.g. PQ
  /// unavailable → offer standard), never silently downgrades. Returns null
  /// when the user declined or the view model is gone.
  Future<Track?> resolveTrackForSend(
    Track track,
    ChatTrackConfirm confirm,
  ) async {
    var chosen = track;
    final xmpp = _xmpp;
    final peerStr = peerJid;
    final peer = JID.fromString(peerStr).toBare();
    final isGroup = state.isGroup;
    final mucEncryptable = state.mucEncryptable;

    final TrackResolution resolution;
    if (isGroup) {
      if (!mucEncryptable) {
        // Public / anonymous rooms: plaintext only.
        resolution = const TrackResolution(track: Track.none, blocked: null);
        chosen = Track.none;
      } else {
        resolution = await xmpp.resolveGroupchatTrack(
          roomJid: peer.toString(),
          requested: chosen,
        );
      }
    } else if (chosen == Track.none) {
      // Plaintext does not depend on what the peer publishes: there is no
      // device list to read and nothing to encrypt. Asking the capability
      // service here used to make a plaintext send wait on (and sometimes
      // hang behind) a PEP lookup whenever the connection was down.
      resolution = const TrackResolution(track: Track.none, blocked: null);
    } else {
      final caps = await xmpp.capabilitiesFor(peer);
      resolution = resolveTrack(requested: chosen, capabilities: caps);
    }

    if (chosen == Track.none) {
      final alternative =
          resolution.alternative ??
          (mucEncryptable || !isGroup ? Track.standard : Track.none);
      if (_disposed) return null;
      // Asked once per conversation, not once per message.
      final db = _db;
      final acknowledged = await db.plaintextAcknowledged(peerStr);
      if (_disposed) return null;
      if (!acknowledged) {
        final agreed = await confirm.confirmPlaintext(
          contact: peerStr,
          alternative: alternative,
        );
        if (!agreed || _disposed) return null;
        await db.acknowledgePlaintext(peerStr);
      }
    } else if (!resolution.canSend) {
      // Refuse and explain. Nothing is sent here, and nothing is sent on
      // another track without a separate decision from the user.
      final alternative = resolution.alternative ?? Track.standard;
      if (_disposed || resolution.blocked == null) return null;
      final substituted = await confirm.askTrackSubstitute(
        blocked: resolution.blocked!,
        alternative: alternative,
      );
      if (substituted == null || _disposed) return null;
      if (substituted == Track.none) {
        // Deliberate downgrade to plaintext from the substitute dialog.
        final agreed = await confirm.confirmPlaintext(
          contact: peerStr,
          alternative: Track.standard,
        );
        if (!agreed || _disposed) return null;
      }
      chosen = substituted;
    }
    return chosen;
  }

  /// Sends [text] on the conversation's track, asking via [confirm] when it
  /// cannot be used. The page owns the composer: it clears the input when
  /// [ChatSendResult.queued] is true (row already in the local DB).
  Future<ChatSendResult> sendText(
    String text, {
    required ChatTrackConfirm confirm,
    required AppLocalizations l10n,
    ChatReplyTarget? reply,
  }) async {
    if (state.sending) return const ChatSendResult();
    _set((s) => s.copyWith(sending: true));
    try {
      final track = await ref.read(chatTrackProvider(arg).future);
      return await _sendOn(track, text.trim(), confirm, reply, l10n);
    } finally {
      _set((s) => s.copyWith(sending: false));
    }
  }

  Future<ChatSendResult> _sendOn(
    Track track,
    String text,
    ChatTrackConfirm confirm,
    ChatReplyTarget? reply,
    AppLocalizations l10n,
  ) async {
    if (text.isEmpty) return const ChatSendResult();

    var chosen = track;
    final xmpp = _xmpp;
    final peerStr = peerJid;
    final peer = JID.fromString(peerStr).toBare();
    final isGroup = state.isGroup;

    // Public / anonymous rooms: plaintext only (Conversations).
    if (isGroup && !state.mucEncryptable) chosen = Track.none;

    // Conversations nextCounterpart: MUC PM is type=chat to room/nick.
    final pmNick = state.mucPmNick;
    final mucPm = isGroup && pmNick != null && pmNick.isNotEmpty;
    final sendTo = mucPm ? JID.fromString('$peerStr/$pmNick') : peer;
    final messageType = mucPm ? 'chat' : (isGroup ? 'groupchat' : 'chat');
    if (mucPm) chosen = Track.none;

    // Queue the row *before* resolving the track.
    //
    // [resolveTrackForSend] reads the peer's PEP device list and probes a
    // bundle per device, which on an account with a long history is tens of
    // seconds. The message must not be invisible for that long, so the bubble
    // goes up now carrying the track the composer is set to, and the
    // resolution below either confirms it or rewrites it. The id is allocated
    // first so the row and the stanza share one [stanzaId].
    final stanzaId = xmpp.allocateStanzaId();
    await MessagesService(_db).insertMessage(
      MessagesCompanion(
        chatJid: Value(peerStr),
        sender: const Value('me'),
        stanzaId: Value(stanzaId),
        body: Value(text),
        timestamp: Value(DateTime.now()),
        encMode: Value((await _xmpp.encModeForPeer(peerStr, chosen)).wire),
        incoming: const Value(false),
        sendStatus: const Value(MessageSendStatus.waiting),
        replyTo: Value(reply?.id ?? ''),
        replyBody: Value(reply?.body ?? ''),
        replyAuthor: Value(reply?.author ?? ''),
      ),
    );
    if (_disposed) {
      // The page is gone, so the send below would be abandoned anyway
      // ([resolveTrackForSend] answers "cancelled" once disposed). Leaving the
      // placeholder behind would park a message on the clock forever.
      await _db.deleteOutgoingByStanzaId(peerStr, stanzaId);
      return const ChatSendResult();
    }

    // The row is local, so the composer may take the next message: holding the
    // re-entrancy guard across the whole resolution is what made a second send
    // wait on the first one's round-trips.
    if (state.sending) _set((s) => s.copyWith(sending: false));

    // Only now the part that may need the network, and may need to ask.
    final Track? resolved;
    try {
      resolved = await resolveTrackForSend(chosen, confirm);
    } catch (e, st) {
      // A lookup that throws must not strand the placeholder row on the clock.
      // The composer has already been cleared, so the visible failure belongs
      // to the bubble.
      _log.warning('resolving a track for $peerStr failed', e, st);
      return _failQueued(peerStr, stanzaId, xmpp, l10n);
    }
    if (resolved == null) {
      // Cancelled at a track dialog. The row was only ever a placeholder, so
      // drop it: a message the user chose not to send must not linger as a
      // failed bubble.
      await _db.deleteOutgoingByStanzaId(peerStr, stanzaId);
      return const ChatSendResult();
    }

    final SendOutcome outcome;
    try {
      if (resolved != chosen) {
        chosen = resolved;
        await _db.updateEncMode(
          peerStr,
          stanzaId,
          (await _xmpp.encModeForPeer(peerStr, chosen)).wire,
        );
      }

      outcome = reply == null
          ? await xmpp.sendOnTrack(
              sendTo,
              text,
              track: chosen,
              messageType: messageType,
              originId: stanzaId,
            )
          : await sendReply(
              xmpp,
              to: sendTo,
              body: text,
              targetId: reply.id,
              track: chosen,
              quoteBody: reply.body,
              messageType: messageType,
              originId: stanzaId,
            );
    } catch (e, st) {
      // Sending while the socket is down can throw (or the connection can be
      // torn down between the row insert and the write). Keeping the row as
      // `waiting` would show a clock forever with nothing left to move it, so
      // record an actionable failure instead.
      _log.warning('sending to $peerStr failed', e, st);
      return _failQueued(peerStr, stanzaId, xmpp, l10n);
    }
    if (!outcome.sent) {
      final reason =
          outcome.blocked?.localizedTitle(l10n) ?? l10n.unknownReason;
      await _db.updateSendStatus(
        peerStr,
        stanzaId,
        MessageSendStatus.sendFailed,
        deliveryError: reason,
      );
      return ChatSendResult(
        queued: true,
        outcome: outcome,
        failureReason: reason,
      );
    }

    // Accepted onto the socket — one tick until 0184 / MUC reflection.
    await _db.updateSendStatus(peerStr, stanzaId, MessageSendStatus.send);
    return ChatSendResult(queued: true, outcome: outcome);
  }

  /// Marks the already-inserted placeholder as failed after an exception.
  ///
  /// The row exists, so [ChatSendResult.queued] stays true: the page must not
  /// put the text back into the composer on top of the failed bubble.
  Future<ChatSendResult> _failQueued(
    String peerStr,
    String stanzaId,
    XmppService xmpp,
    AppLocalizations l10n,
  ) async {
    final reason = xmpp.state == XmppConnectionState.connected
        ? l10n.unknownReason
        : l10n.notConnectedTryAgain;
    await _db.updateSendStatus(
      peerStr,
      stanzaId,
      MessageSendStatus.sendFailed,
      deliveryError: reason,
    );
    return ChatSendResult(queued: true, failureReason: reason);
  }

  /// Fails any outgoing row still `waiting` from a previous run.
  ///
  /// Rows are inserted before the track/socket work, so a crash or a send
  /// path that threw outside its own handler leaves one on the clock with
  /// nothing left to advance it. Anything older than [staleAfter] cannot
  /// belong to an in-flight send in this process.
  Future<int> reconcileStaleWaiting({
    required String reason,
    Duration staleAfter = const Duration(minutes: 2),
  }) => _db.failStaleOutgoingWaiting(
    peerJid,
    before: DateTime.now().subtract(staleAfter),
    reason: reason,
  );

  /// Whether the server offers XEP-0363 upload.
  Future<bool> isUploadAvailable() => _xmpp.httpFiles.isAvailable();

  /// Shows / hides the page's picker barrier.
  void setPickingFile(bool picking) =>
      _set((s) => s.copyWith(pickingFile: picking));

  /// Uploads and sends [bytes] already chosen by the page's file picker.
  Future<ChatAttachResult> sendAttachmentBytes(
    List<int> bytes, {
    required String fileName,
    required ChatTrackConfirm confirm,
    required AppLocalizations l10n,
    String? mimeOverride,
  }) async {
    if (state.sending) return const ChatAttachResult();
    final xmpp = _xmpp;
    final peerStr = peerJid;
    final isGroup = state.isGroup;
    final plainRoom = isGroup && !state.mucEncryptable;
    _set((s) => s.copyWith(sending: true));
    try {
      final track = plainRoom
          ? Track.none
          : await ref.read(chatTrackProvider(arg).future);
      // Same resolve / substitute dialog as text (incl. MUC PQ → standard).
      final outcomeTrack = await resolveTrackForSend(
        plainRoom ? Track.none : track,
        confirm,
      );
      if (outcomeTrack == null) return const ChatAttachResult();

      final data = Uint8List.fromList(bytes);
      final uploaded = await xmpp.httpFiles.uploadBytes(
        data,
        fileName: fileName,
        encrypt: outcomeTrack != Track.none,
        mimeOverride: mimeOverride,
      );
      final cached = await xmpp.httpFiles.cacheLocalBytes(
        data,
        preferredName: uploaded.fileName,
      );
      final pmNick = state.mucPmNick;
      final mucPm = isGroup && pmNick != null && pmNick.isNotEmpty;
      final sendTo = mucPm
          ? JID.fromString('$peerStr/$pmNick')
          : JID.fromString(peerStr);
      final fileTrack = mucPm ? Track.none : outcomeTrack;
      final messageType = mucPm ? 'chat' : (isGroup ? 'groupchat' : 'chat');

      // Same insert-first path as text (Conversations).
      final stanzaId = xmpp.allocateStanzaId();
      await MessagesService(_db).insertMessage(
        MessagesCompanion(
          chatJid: Value(peerStr),
          sender: const Value('me'),
          stanzaId: Value(stanzaId),
          body: Value(uploaded.shareUrl),
          timestamp: Value(DateTime.now()),
          encMode: Value((await xmpp.encModeForPeer(peerStr, fileTrack)).wire),
          incoming: const Value(false),
          sendStatus: const Value(MessageSendStatus.waiting),
          mediaUrl: Value(uploaded.shareUrl),
          mediaMime: Value(uploaded.mime),
          mediaName: Value(uploaded.fileName),
          localPath: Value(cached.path),
        ),
      );

      final outcome = await xmpp.sendOnTrack(
        sendTo,
        uploaded.shareUrl,
        track: fileTrack,
        oobUrl: uploaded.shareUrl,
        messageType: messageType,
        originId: stanzaId,
      );
      if (!outcome.sent) {
        final reason =
            outcome.blocked?.localizedTitle(l10n) ?? l10n.unknownReason;
        await _db.updateSendStatus(
          peerStr,
          stanzaId,
          MessageSendStatus.sendFailed,
          deliveryError: reason,
        );
        return ChatAttachResult(queued: true, failureReason: reason);
      }

      await _db.updateSendStatus(peerStr, stanzaId, MessageSendStatus.send);
      return const ChatAttachResult(sent: true, queued: true);
    } catch (e) {
      return ChatAttachResult(error: '$e');
    } finally {
      _set((s) => s.copyWith(sending: false));
    }
  }

  Stream<List<Sticker>> watchStickers() => _db.watchStickers();

  /// Saves image bytes with every send-link left empty.
  ///
  /// A hash that is already stored returns that row instead of inserting.
  Future<StickerSave> saveStickerImage(Uint8List image, String mime) =>
      _db.addSticker(image: image, mime: mime);

  Future<void> deleteSticker(int id) => _db.deleteSticker(id);

  /// Sends a saved sticker on the current track.
  ///
  /// The link stored for that track is sent as-is when it is still inside
  /// 30 days. An empty link, or one older than that, is uploaded first and
  /// written back. The other two tracks are not touched.
  Future<ChatAttachResult> sendSticker(
    Sticker sticker, {
    required ChatTrackConfirm confirm,
    required AppLocalizations l10n,
  }) async {
    if (state.sending) return const ChatAttachResult();
    final xmpp = _xmpp;
    final peerStr = peerJid;
    final isGroup = state.isGroup;
    final plainRoom = isGroup && !state.mucEncryptable;
    _set((s) => s.copyWith(sending: true));
    try {
      final track = plainRoom
          ? Track.none
          : await ref.read(chatTrackProvider(arg).future);
      final outcomeTrack = await resolveTrackForSend(
        plainRoom ? Track.none : track,
        confirm,
      );
      if (outcomeTrack == null) return const ChatAttachResult();

      final pmNick = state.mucPmNick;
      final mucPm = isGroup && pmNick != null && pmNick.isNotEmpty;
      final fileTrack = mucPm ? Track.none : outcomeTrack;
      final kind = switch (fileTrack) {
        Track.none => StickerSendKind.plain,
        Track.standard => StickerSendKind.omemo,
        Track.pq => StickerSendKind.pq,
      };
      final fresh = await _db.stickerById(sticker.id);
      if (fresh == null) return const ChatAttachResult();

      final slot = switch (kind) {
        StickerSendKind.plain => (
          url: fresh.plainUrl,
          at: fresh.plainUploadedAt,
        ),
        StickerSendKind.omemo => (
          url: fresh.omemoUrl,
          at: fresh.omemoUploadedAt,
        ),
        StickerSendKind.pq => (url: fresh.pqUrl, at: fresh.pqUploadedAt),
      };
      final now = DateTime.now();
      late final String shareUrl;
      late final String mime;
      late final String fileName;
      if (stickerLinkUsable(
        url: slot.url,
        uploadedAt: slot.at,
        kind: kind,
        now: now,
      )) {
        shareUrl = slot.url.trim();
        mime = fresh.mime;
        fileName = stickerUploadName(fresh.id, fresh.mime);
      } else {
        if (!await xmpp.httpFiles.isAvailable()) {
          return const ChatAttachResult(uploadUnavailable: true);
        }
        final uploaded = await xmpp.httpFiles.uploadBytes(
          fresh.image,
          fileName: stickerUploadName(fresh.id, fresh.mime),
          encrypt: fileTrack != Track.none,
          mimeOverride: fresh.mime,
        );
        shareUrl = uploaded.shareUrl;
        mime = uploaded.mime;
        fileName = uploaded.fileName;
        final uploadedAt = DateTime.now();
        if (stickerLinkUsable(
          url: shareUrl,
          uploadedAt: uploadedAt,
          kind: kind,
          now: uploadedAt,
        )) {
          await _db.rememberStickerLink(
            id: fresh.id,
            kind: kind,
            url: shareUrl,
            uploadedAt: uploadedAt,
          );
        }
      }

      final cached = await xmpp.httpFiles.cacheLocalBytes(
        fresh.image,
        preferredName: fileName,
      );
      final sendTo = mucPm
          ? JID.fromString('$peerStr/$pmNick')
          : JID.fromString(peerStr);
      final messageType = mucPm ? 'chat' : (isGroup ? 'groupchat' : 'chat');
      final stanzaId = xmpp.allocateStanzaId();
      await MessagesService(_db).insertMessage(
        MessagesCompanion(
          chatJid: Value(peerStr),
          sender: const Value('me'),
          stanzaId: Value(stanzaId),
          body: Value(shareUrl),
          timestamp: Value(DateTime.now()),
          encMode: Value((await xmpp.encModeForPeer(peerStr, fileTrack)).wire),
          incoming: const Value(false),
          sendStatus: const Value(MessageSendStatus.waiting),
          mediaUrl: Value(shareUrl),
          mediaMime: Value(mime),
          mediaName: Value(fileName),
          localPath: Value(cached.path),
        ),
      );

      final outcome = await xmpp.sendOnTrack(
        sendTo,
        shareUrl,
        track: fileTrack,
        oobUrl: shareUrl,
        messageType: messageType,
        originId: stanzaId,
      );
      if (!outcome.sent) {
        final reason =
            outcome.blocked?.localizedTitle(l10n) ?? l10n.unknownReason;
        await _db.updateSendStatus(
          peerStr,
          stanzaId,
          MessageSendStatus.sendFailed,
          deliveryError: reason,
        );
        return ChatAttachResult(queued: true, failureReason: reason);
      }

      await _db.updateSendStatus(peerStr, stanzaId, MessageSendStatus.send);
      return const ChatAttachResult(sent: true, queued: true);
    } catch (e) {
      return ChatAttachResult(error: '$e');
    } finally {
      _set((s) => s.copyWith(sending: false));
    }
  }

  // --- Reactions / retraction / correction ----------------------------------

  /// Bumped whenever a reaction is stored, to invalidate every chip strip.
  void bumpReactions() {
    if (_disposed) return;
    final bump = ref.read(reactionRevisionProvider.notifier);
    bump.state = bump.state + 1;
  }

  /// Adds or withdraws [emoji] on the message addressed by [targetId].
  ///
  /// Withdrawing sends an *empty* set, not a set without that emoji: XEP-0444
  /// broadcasts are complete lists, so anything else leaves the withdrawn row
  /// on the sender's device forever.
  ///
  /// Optimistic in both directions, and rolled back if the send fails — a chip
  /// that appears a second late feels broken, and one that stays after a
  /// failure is a lie. Returns false when the send failed (and was rolled
  /// back).
  Future<bool> toggleReaction(String targetId, String emoji) async {
    final r = resolveChatKey(arg);
    final db = r.session.db;
    final xmpp = r.session.xmpp;
    final myJid = xmpp.myJid;
    if (myJid == null || targetId.isEmpty) return true;
    // Captured now: the page (and with it this view model) may be gone before
    // the send returns, and the chips elsewhere should still refresh.
    final bumpController = ref.read(reactionRevisionProvider.notifier);
    void bump() => bumpController.state = bumpController.state + 1;

    final before = await reactionsFor(db, targetId, myJid);
    final mine = before.where((g) => g.mine).toList();
    final next = <String>{for (final g in mine) g.emoji};
    if (next.remove(emoji)) {
      // withdrawing
    } else {
      next.add(emoji);
    }

    await r.session.messages.storeReaction(
      ReactionUpdate(targetId: targetId, reactor: myJid, emojis: next.toList()),
    );
    bump();

    final sent = await sendReaction(
      xmpp,
      to: JID.fromString(r.jid).toBare(),
      targetId: targetId,
      emojis: next.toList(),
    );
    if (sent) return true;

    // Put the chips back exactly as they were. Re-sending the whole previous
    // set rather than just undoing this one emoji keeps the local state equal
    // to what the last successful broadcast said.
    final previous = <String>{for (final g in mine) g.emoji};
    await r.session.messages.storeReaction(
      ReactionUpdate(
        targetId: targetId,
        reactor: myJid,
        emojis: previous.toList(),
      ),
    );
    bump();
    return false;
  }

  /// Retracts [targetId], then applies it locally.
  ///
  /// Our own messages go out as XEP-0424. In a group, a moderator retracts
  /// someone else's message with XEP-0425: an IQ to the room, addressed by
  /// the room stanza-id. The local copy is updated only after the send
  /// succeeded.
  ///
  /// [targetId] is the id we stored (origin-id).
  Future<bool> retractMessage(String targetId) async {
    final r = resolveChatKey(arg);
    final chat = await r.session.db.getChat(r.jid);
    final row = await r.session.db.messageWithStanzaId(r.jid, targetId);
    if (row == null) return false;
    final group = chat?.isGroup ?? false;
    final xmpp = r.session.xmpp;
    if (row.incoming) {
      if (!group || row.roomStanzaId.isEmpty) return false;
      if (!await xmpp.canModerate(r.jid)) return false;
      final sent = await xmpp.moderateMessage(
        JID.fromString(r.jid).toBare(),
        stanzaId: row.roomStanzaId,
      );
      if (!sent) return false;
      final nick = chat?.mucNick ?? '';
      await r.session.messages.markRetracted(
        targetId,
        by: nick.isEmpty ? null : nick,
      );
      return true;
    }
    // A group retraction that names the origin-id does not match the message
    // other clients have. They show the notice and leave the message in place.
    if (group && row.roomStanzaId.isEmpty) return false;
    final wireId = group ? row.roomStanzaId : targetId;
    final sent = await retraction.retractMessage(
      xmpp,
      chatJid: r.jid,
      targetId: wireId,
      groupchat: group,
    );
    if (!sent) return false;
    await r.session.messages.markRetracted(targetId);
    return true;
  }

  /// Sends a correction for [targetId] and stores it.
  ///
  /// Sent on the conversation's current track, like any other message: a
  /// correction of an encrypted message must not travel in the clear, or the
  /// server learns the corrected text. Returns null on success, otherwise the
  /// reason it was not corrected.
  Future<String?> submitCorrection(
    String targetId,
    String body, {
    required AppLocalizations l10n,
  }) async {
    final r = resolveChatKey(arg);
    final outcome = await r.session.xmpp.correctMessage(
      JID.fromString(r.jid).toBare(),
      targetId: targetId,
      body: body,
    );
    if (!outcome.sent) {
      return outcome.blocked?.localizedTitle(l10n) ?? l10n.unknownReason;
    }
    await r.session.messages.applyCorrection(
      chatJid: r.jid,
      targetId: targetId,
      body: body,
      encMode: (await r.session.xmpp.encModeForPeer(r.jid, outcome.track)).wire,
    );
    return null;
  }

  /// Retracts the ones among [ids] that we sent.
  ///
  /// Only ours: XEP-0424 is an instruction to the recipient's own client, so
  /// retracting somebody else's message would change only our copy.
  Future<ChatDeleteResult> deleteMineByIds(List<String> ids) async {
    final r = resolveChatKey(arg);
    final chat = await r.session.db.getChat(r.jid);
    final group = chat?.isGroup ?? false;
    final messages = await r.session.db.watchMessages(r.jid).first;
    final mine = [
      for (final m in messages)
        if (ids.contains(m.stanzaId) && !m.incoming) m,
    ];
    var deleted = 0;
    for (final row in mine) {
      if (group && row.roomStanzaId.isEmpty) continue;
      final wireId = group ? row.roomStanzaId : row.stanzaId;
      final ok = await retraction.retractMessage(
        r.session.xmpp,
        chatJid: r.jid,
        targetId: wireId,
        groupchat: group,
      );
      if (!ok) break;
      await r.session.messages.markRetracted(row.stanzaId);
      deleted++;
    }
    return (mine: mine.length, deleted: deleted);
  }

  // --- Forwarding -----------------------------------------------------------

  /// Forwards [items] into the conversation [targetKey].
  ///
  /// Sent again as a new, re-encrypted message rather than reusing the
  /// original stanza: a wrapped stanza carries encryption meant for somebody
  /// else, so forwarding by reuse would either fail silently or hand the new
  /// recipient the previous conversation's keys.
  Future<ChatForwardResult> forwardToChat({
    required List<ForwardItem> items,
    required String targetKey,
  }) async {
    final dest = resolveChatKey(targetKey);
    final destPeer = dest.jid;
    // Refuse to forward into a blocked conversation: the user blocked them,
    // and the act of forwarding is a message to them.
    if (ref.read(isBlockedProvider(targetKey))) {
      return ChatForwardResult(destPeer: destPeer, blocked: true);
    }
    var track = await ref.read(chatTrackProvider(targetKey).future);
    if (_disposed) return ChatForwardResult(destPeer: destPeer);

    final chat = await dest.session.db.getChat(destPeer);
    final isGroup = chat?.isGroup ?? false;
    final mucEncryptable = chat?.mucPrivateNonAnonymous ?? false;
    // Public / anonymous rooms: plaintext only (same as sendText).
    if (isGroup && !mucEncryptable) track = Track.none;
    final messageType = isGroup ? 'groupchat' : 'chat';

    final outcome = await forwardMessages(
      dest.session.xmpp,
      toJid: JID.fromString(destPeer).toBare(),
      items: items,
      track: track,
      messageType: messageType,
    );
    // Persist what went out into the destination chat — otherwise the sender
    // sees an empty history and assumes nothing was delivered.
    if (outcome.ok) {
      final now = DateTime.now();
      for (var i = 0; i < outcome.stanzaId.length; i++) {
        await dest.session.messages.insertMessage(
          MessagesCompanion(
            chatJid: Value(destPeer),
            sender: const Value('me'),
            stanzaId: Value(outcome.stanzaId[i]),
            body: Value(outcome.wireBodies[i]),
            timestamp: Value(now.add(Duration(milliseconds: i))),
            encMode: Value(
              (await dest.session.xmpp.encModeForPeer(destPeer, track)).wire,
            ),
            incoming: const Value(false),
            // Already on the wire from [forwardMessages].
            sendStatus: const Value(MessageSendStatus.send),
          ),
        );
      }
    }
    return ChatForwardResult(destPeer: destPeer, outcome: outcome);
  }

  // --- Misc reads -----------------------------------------------------------

  /// Whether the message with [stanzaId] is pinned in this chat.
  Future<bool> isPinned(String stanzaId) => _db.isPinned(peerJid, stanzaId);

  /// Pins or unpins a message.
  Future<void> togglePinned(String stanzaId) =>
      _db.togglePinned(peerJid, stanzaId);

  /// Bodies of the pinned messages in [ids], keyed by stanza id.
  Future<Map<String, ({String body, String sender, DateTime at})>> pinnedBodies(
    List<String> ids,
  ) async {
    final messages = await _db.watchMessages(peerJid).first;
    return {
      for (final m in messages)
        if (ids.contains(m.stanzaId))
          m.stanzaId: (body: m.body, sender: m.sender, at: m.timestamp),
    };
  }

  /// Fetches MAM history; returns how many messages arrived, or null on
  /// failure. A room is queried on itself, not via the account archive.
  Future<int?> loadHistory() async {
    final chat = await _db.getChat(peerJid);
    return _xmpp.fetchHistory(
      JID.fromString(peerJid),
      group: chat?.isGroup ?? state.isGroup,
    );
  }

  /// True once an older-history page reported the archive has nothing further.
  Future<bool> olderHistoryExhausted() => _db.mamOlderExhausted(peerJid);

  Future<void> setOlderHistoryExhausted(bool exhausted) =>
      _db.setMamOlderExhausted(peerJid, exhausted);

  /// One page of messages older than [end] (Conversations page size).
  ///
  /// [beforeId] continues from the previous page's RSM cursor when that page
  /// did not add a row. Null when the query failed.
  Future<({int count, bool complete, String? first})?> loadOlder({
    required DateTime end,
    String? beforeId,
  }) async {
    final chat = await _db.getChat(peerJid);
    return _xmpp.fetchOlderHistory(
      JID.fromString(peerJid),
      group: chat?.isGroup ?? state.isGroup,
      end: end,
      beforeId: beforeId,
    );
  }
}
