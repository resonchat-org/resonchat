// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Chat page. Layout and interactions follow Telegram for Android's
// `ChatActivity` (GPL-2.0-or-later), translated to Flutter.

import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:mime/mime.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../account/account_hub.dart';
import '../../account/chat_ref.dart';
import '../../account/resolve.dart';
import '../../l10n/l10n.dart';
import '../../crypto/omemo/track.dart';
import '../../platform/app_notifications.dart';
import '../../platform/media_store.dart';
import '../../platform/voice_recorder.dart';
import '../../state/providers.dart';
import '../../store/database.dart';
import '../../store/sticker_link.dart';
import '../../translate/translatable_text.dart';
import '../../translate/translation_prefs.dart';
import '../../translate/translation_service.dart';
import '../../untracker/prefs.dart';
import '../../untracker/untracker.dart';
import '../../xmpp/connection.dart';
import '../../xmpp/last_seen.dart';
import '../../xmpp/presence_store.dart';
import '../../xmpp/forwarding.dart';
import '../../xmpp/local_nickname.dart';
import '../../xmpp/muc.dart';
import '../../xmpp/reactions.dart';
import '../contact_avatar.dart';
import '../../utils/appearance.dart';
import 'chat_input_bar.dart';
import 'media_attachment.dart';
import 'sticker_panel.dart';
import 'chat_message_list.dart';
import 'chat_nicks.dart';
import 'chat_subscription_banner.dart';
import 'chat_topic_banner.dart';
import 'chat_wallpaper.dart';
import 'conference_mention.dart';
import 'quoted_transcript.dart';
import 'message_actions.dart';
import '../home/open_chat.dart';
import '../room/occupant_actions.dart';
import '../room/room_profile_page.dart';
import '../room/room_sheet.dart';
import '../chats/search.dart';
import 'track_dialogs.dart';
import 'chat_viewmodel.dart';
import '../theme.dart';

class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({
    super.key,
    required this.chatJid,
    this.focusMessageAnchor,
    this.embedded = false,
  });

  /// [ChatRef.key] (accountId + peer JID), or legacy bare JID.
  final String chatJid;

  /// When set (e.g. from search), open scrolled to this message instead of
  /// unread / bottom. Same encoding as [unreadAnchorOf].
  final String? focusMessageAnchor;

  /// Shown in the home shell side pane (column mode); no route stack back.
  final bool embedded;

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  /// Peer bare JID for XMPP (not the opaque [ChatRef.key]).
  String get _peerJid => resolveChatKey(widget.chatJid).jid;

  /// Domain logic and UI state live in the view model; this State keeps only
  /// what needs a `BuildContext` or a widget controller.
  late ChatViewModel _vm;
  StreamSubscription<String>? _failureNoticeSub;
  StreamSubscription<String>? _noticeSub;

  /// Transient send/connection notice shown above the composer.
  ///
  /// Kept as an inline banner rather than a [SnackBar]: a fixed SnackBar is
  /// painted by the Scaffold over the body's floating input island and hides
  /// the composer (issue #8). Carries an optional "details" action.
  ({String message, VoidCallback? onDetails})? _notice;

  Timer? _noticeTimer;

  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _focus = FocusNode();
  var _stickersOpen = false;
  Stream<List<Sticker>>? _stickers;

  /// Avatar-tap @-mentions (Conversations `highlightInConference`).
  final _mentions = ConferenceMentionSession();

  bool _atBottom = true;

  /// Unread count for this conversation, or null while it is being read.
  ///
  /// Watched here rather than only in the chat list because the jump-to-unread
  /// button has to know about it, and the chat page is not rebuilt by the list.
  int? get _unreadCountHere =>
      ref.watch(chatUnreadProvider(widget.chatJid)).value;

  /// Key on the unread divider, so the jump button can scroll to exactly it.
  ///
  /// On the divider rather than on the first unread message: the divider is
  /// already in the right place, it exists exactly once, and scrolling to a row
  /// by index means guessing a pixel offset from a row height that depends on
  /// the text inside every row.
  final _unreadDividerKey = GlobalKey();

  /// Key attached to the search-focus message row.
  final _focusMessageKey = GlobalKey();

  /// Override from in-chat search; [ChatPage.focusMessageAnchor] for deep links.
  String? _focusMessageAnchor;

  String? get _activeFocusAnchor =>
      _focusMessageAnchor ?? widget.focusMessageAnchor;

  /// Scrolls so [key]'s render object sits near [alignment] in the viewport.
  ///
  /// Uses [RenderAbstractViewport.getOffsetToReveal] rather than
  /// [Scrollable.ensureVisible]: the transcript sits under a [CustomPaint]
  /// wallpaper, and ensureVisible has been a silent no-op there.
  void _jumpToKeyedWidget(
    GlobalKey key, {
    bool animate = true,
    double alignment = 0.33,
  }) {
    final target = key.currentContext;
    if (target == null || !_scroll.hasClients) return;
    final renderObject = target.findRenderObject();
    if (renderObject == null || !renderObject.attached) return;
    final viewport = RenderAbstractViewport.maybeOf(renderObject);
    if (viewport == null) return;
    final revealed = viewport.getOffsetToReveal(renderObject, alignment).offset;
    final offset = revealed.clamp(
      _scroll.position.minScrollExtent,
      _scroll.position.maxScrollExtent,
    );
    if (animate) {
      unawaited(
        _scroll.animateTo(
          offset,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOut,
        ),
      );
    } else {
      _scroll.jumpTo(offset);
    }
  }

  void _jumpToUnread({bool animate = true}) =>
      _jumpToKeyedWidget(_unreadDividerKey, animate: animate);

  void _jumpToFocusMessage({bool animate = true}) =>
      _jumpToKeyedWidget(_focusMessageKey, animate: animate, alignment: 0.35);

  Future<void> _openInChatSearch() async {
    final hit = await Navigator.of(context).push<SearchHit>(
      MaterialPageRoute(builder: (_) => SearchPage(chatJid: widget.chatJid)),
    );
    if (!mounted || hit == null) return;
    setState(() => _focusMessageAnchor = hit.messageAnchor);
    void jump({required int attempt}) {
      if (!mounted) return;
      if (_focusMessageKey.currentContext != null && _scroll.hasClients) {
        _jumpToFocusMessage();
        return;
      }
      if (attempt < 12) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => jump(attempt: attempt + 1),
        );
      }
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => jump(attempt: 0));
  }

  /// True after the first open has positioned the transcript.
  ///
  /// Priority: search focus → unread divider → latest message.
  bool _didInitialScroll = false;

  /// The message being corrected, or null. Held as an id rather than a row so
  /// an edit survives the list rebuilding underneath it.
  String? _editingId;
  String _editingBody = '';

  /// In-memory translations for the open chat, keyed by stanza id.
  final Map<String, String> _translations = {};

  /// Stanza ids with a Translate request in flight.
  final Set<String> _translating = {};

  /// Id of the message whose quick-reaction strip is open, or null.
  String? _reactingToId;

  /// Database id of the text message showing a live selection, or null.
  int? _selectingMessageId;

  /// The slice Copy selection should copy. Updated without rebuilding.
  String _selectedSlice = '';

  /// The message being replied to: its id, its text, and who wrote it.
  ///
  /// Held as three values rather than a row because the transcript rebuilds
  /// underneath the composer, and a reply composer pointing at a row it no
  /// longer holds would quote nothing.
  ({String id, String body, String author})? _replyingTo;

  /// Stanza ids currently selected, in selection order.
  ///
  /// An ordered set rather than a bool per message because the order the user
  /// picked them in is the order they are forwarded in, and "select five
  /// messages and get them shuffled" is its own bug.
  final _selection = <String>[];

  bool get _selectionMode => _selection.isNotEmpty;

  /// UI state owned by the view model (group/MUC, typing, advice, sending…).
  ChatUiState get _ui => ref.read(chatViewModelProvider(widget.chatJid));

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _focus.addListener(_onComposerFocus);
    _bindViewModel();
    // Deliberately *not* marked read here. Marking on arrival would clear the
    // unread badge before the user has read anything, and the boundary in the
    // transcript would vanish before it had been seen. The marker advances when
    // the page goes away, which is also the moment the badge in the chat list
    // should stop counting these messages.
    //
    // Marking on "a message scrolled past" would be worse: a message the user
    // scrolled past deliberately, on purpose, is not unread.

    // Conversations sends <displayed/> when the conversation is marked read
    // (opening / viewing). Fire once the first frame is up so unread inbound
    // messages get a read receipt without waiting until the user leaves.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(openChatKeyProvider.notifier).state = widget.chatJid;
      _clearShadeForOpenChat();
      // Groupchat does not use 1:1 displayed markers the same way.
      if (!_ui.isGroup) unawaited(_vm.sendDisplayedForLatest());
    });
  }

  void _clearShadeForOpenChat() {
    final chatRef = ChatRef.tryParse(widget.chatJid);
    if (chatRef == null) return;
    unawaited(
      AppNotifications.instance.cancelChat(
        accountId: chatRef.accountId,
        chatJid: chatRef.jid,
      ),
    );
  }

  /// Attaches to the view model for [ChatPage.chatJid]: the provider build
  /// starts its subscriptions; here we only listen for what needs a snackbar.
  void _bindViewModel() {
    _vm = ref.read(chatViewModelProvider(widget.chatJid).notifier);
    _stickers = _vm.watchStickers();
    _failureNoticeSub?.cancel();
    _noticeSub?.cancel();
    _failureNoticeSub = _vm.failureNotices.listen(_onFailureNotice);
    _noticeSub = _vm.notices.listen(_showNotice);
  }

  @override
  void didUpdateWidget(ChatPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Each conversation has its own view model (advice, typing and room state
    // included), so switching chats just means attaching to the new one.
    if (oldWidget.chatJid != widget.chatJid) {
      _bindViewModel();
      // Defer: didUpdateWidget runs inside the parent rebuild, and writing a
      // StateProvider here re-enters Riverpod mid-notify (listener exception).
      final key = widget.chatJid;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref.read(openChatKeyProvider.notifier).state = key;
        _clearShadeForOpenChat();
      });
    }
  }

  @override
  void deactivate() {
    // Capture before [super.deactivate]: context/ref stay valid here, but
    // clearing must not happen synchronously — the parent (e.g. HomeShell
    // replacing the column pane) is often still rebuilding when we deactivate.
    final container = ProviderScope.containerOf(context);
    final key = widget.chatJid;
    final shouldClear = container.read(openChatKeyProvider) == key;
    super.deactivate();
    if (!shouldClear) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (container.read(openChatKeyProvider) == key) {
        container.read(openChatKeyProvider.notifier).state = null;
      }
    });
  }

  void _onFailureNotice(String reason) {
    if (!mounted) return;
    _showNotice(
      context.l10n.notDelivered(reason),
      onDetails: () => _showRefusalHelp(reason),
    );
  }

  /// Shows a transient inline notice above the composer, then auto-dismisses.
  ///
  /// A SnackBar would be laid out by the Scaffold over the body's floating
  /// input island and hide the field it is warning about; the banner below the
  /// transcript cannot (issue #8). Six seconds is long enough to read a short
  /// reason and short enough to stay out of the way; the close button and the
  /// next notice both dismiss it early.
  void _showNotice(String message, {VoidCallback? onDetails}) {
    if (!mounted) return;
    _noticeTimer?.cancel();
    setState(() => _notice = (message: message, onDetails: onDetails));
    _noticeTimer = Timer(const Duration(seconds: 6), _clearNotice);
  }

  void _clearNotice() {
    _noticeTimer?.cancel();
    _noticeTimer = null;
    if (mounted && _notice != null) setState(() => _notice = null);
  }

  /// Turns the server's error into something actionable.
  ///
  /// `auth/forbidden` in practice means the server refuses stanzas outside a
  /// mutual subscription, which is the single most common reason a fresh
  /// contact sees every message silently vanish.
  void _showRefusalHelp(String reason) {
    final mutual = ref.read(contactStateProvider(widget.chatJid)).value;
    final l10n = context.l10n;
    final body = (mutual?.isMutual ?? false)
        ? l10n.messageNotDeliveredBody(reason)
        : l10n.messageNotDeliveredBodyNotMutual(
            reason,
            mutual?.summary ?? l10n.subscriptionUnknown,
          );
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.messageNotDeliveredTitle),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.close),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    // Leaving is what "read" means. Done here rather than on arrival so the
    // unread boundary stays on screen while it is actually being read, and so
    // the list badge survives a user who opened a chat and left it again
    // without scrolling.
    unawaited(_vm.markReadAndSendDisplayed());
    // Conversations updateChatState on leave: paused if draft remains, else active.
    unawaited(
      _vm.publishComposerChatState(composerEmpty: _input.text.trim().isEmpty),
    );
    _failureNoticeSub?.cancel();
    _noticeSub?.cancel();
    _noticeTimer?.cancel();
    _focus.removeListener(_onComposerFocus);
    _scroll
      ..removeListener(_onScroll)
      ..dispose();
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// AppBar subtitle for a room: members+online when JIDs are visible,
  /// otherwise online count only.
  static String _roomMembersSubtitle(AppLocalizations l10n, GroupChat room) {
    final online = room.onlineOccupantCount;
    if (!room.canSeeMemberJids) {
      return l10n.membersOnlineCount(online);
    }
    return l10n.membersAndOnlineCount(room.affiliatedMemberCount, online);
  }

  /// AppBar subtitle: typing, or presence plus last-seen when every resource
  /// is idle (XEP-0319).
  String _peerStatusSubtitle(
    BuildContext context,
    TypingState peerTyping, {
    required ContactPresence? presence,
  }) {
    final name = _peerJid.split('@').first;
    final l10n = context.l10n;
    return switch (peerTyping) {
      TypingState.composing => l10n.contactIsTyping(name),
      TypingState.paused => l10n.contactStoppedTyping(name),
      TypingState.inactive => () {
        final label = presenceLabel(l10n, presence?.show);
        final seen = lastSeenLine(l10n, presence?.idleSince);
        if (seen == null) return label;
        return '$label ($seen)';
      }(),
    };
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final distance = _scroll.position.maxScrollExtent - _scroll.offset;
    final atBottom = distance < 80;
    if (atBottom != _atBottom) setState(() => _atBottom = atBottom);
  }

  void _scrollToBottom() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      _scroll.position.maxScrollExtent,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  /// Instant jump used on first open (and after layout settles).
  void _jumpToBottom() {
    if (!_scroll.hasClients) return;
    _scroll.jumpTo(_scroll.position.maxScrollExtent);
    if (!_atBottom) setState(() => _atBottom = true);
  }

  /// Open position: search hit, else unread divider, else the latest message.
  ///
  /// Search focus waits until the keyed row has laid out (several frames if
  /// needed). Marking done only after a successful jump stops a race where the
  /// first layout still has no key and the fallback would land on unread /
  /// bottom instead of the hit.
  void _ensureInitialScroll() {
    if (_didInitialScroll) return;
    void place({required int attempt}) {
      if (!mounted || _didInitialScroll) return;
      final focus = _activeFocusAnchor;
      if (focus != null) {
        if (_focusMessageKey.currentContext != null && _scroll.hasClients) {
          _didInitialScroll = true;
          _jumpToFocusMessage(animate: false);
          if (_atBottom) setState(() => _atBottom = false);
          // Layout extents often settle one frame later — re-snap once.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _jumpToFocusMessage(animate: false);
          });
          return;
        }
        if (attempt < 12) {
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => place(attempt: attempt + 1),
          );
          return;
        }
        // Hit not in the loaded transcript — fall through.
      }
      _didInitialScroll = true;
      if (_unreadDividerKey.currentContext != null) {
        _jumpToUnread(animate: false);
        if (_atBottom) setState(() => _atBottom = false);
      } else {
        _jumpToBottom();
      }
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => place(attempt: 0));
  }

  /// Restores the saved draft into the input.
  ///
  /// Only once, and only if the field is still empty — otherwise a rebuild
  /// arriving while the user is typing would overwrite what they just wrote
  /// with the older stored copy.
  bool _draftRestored = false;

  void _restoreDraft() {
    if (_draftRestored) return;
    final draft = ref.read(draftProvider(widget.chatJid)).value;
    if (draft == null || draft.isEmpty) {
      _draftRestored = true;
      return;
    }
    if (_input.text.isNotEmpty) {
      _draftRestored = true;
      return;
    }
    _draftRestored = true;
    _input.text = draft;
    _vm.onDraftRestored(draft);
  }

  /// Dialog hooks for [ChatViewModel.resolveTrackForSend]. Both answer "no"
  /// once this page is gone, so nothing is sent without a decision.
  ChatTrackConfirm get _confirm => ChatTrackConfirm(
    confirmPlaintext: ({required contact, required alternative}) async =>
        mounted &&
        await confirmPlaintext(
          context,
          contact: contact,
          alternative: alternative,
        ),
    askTrackSubstitute: ({required blocked, required alternative}) async =>
        mounted
        ? await askTrackSubstitute(
            context,
            blocked: blocked,
            alternative: alternative,
          )
        : null,
  );

  void _showNotSent(String reason) {
    if (!mounted) return;
    _showNotice(context.l10n.notSent(reason));
  }

  void _onComposerFocus() {
    if (_focus.hasFocus && _stickersOpen && mounted) {
      setState(() => _stickersOpen = false);
    }
  }

  void _toggleStickers() {
    final next = !_stickersOpen;
    setState(() => _stickersOpen = next);
    if (next) _focus.unfocus();
  }

  void _insertStickerText(String text) {
    final value = _input.value;
    final start = value.selection.start < 0
        ? value.text.length
        : value.selection.start;
    final end = value.selection.end < 0
        ? value.text.length
        : value.selection.end;
    final next = value.text.replaceRange(start, end, text);
    _input.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start + text.length),
    );
    _vm.onInputChanged(next);
  }

  String _stickerSaveLabel(StickerSave saved) {
    final l10n = context.l10n;
    return saved.hashMatched ? l10n.stickerAlreadySaved : l10n.stickerSaved;
  }

  bool _canSaveSticker(Message message) {
    if (message.retracted) return false;
    if (!mediaStore.existsSync(message.localPath)) return false;
    final name = message.mediaName.isNotEmpty
        ? message.mediaName
        : message.localPath;
    return isImageMime(message.mediaMime, name);
  }

  /// Copies an already-downloaded image into this account's stickers.
  ///
  /// The send links stay empty. They are written only when this account
  /// sends the sticker.
  Future<void> _saveMessageSticker(Message message) async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final bytes = await mediaStore.readBytes(message.localPath);
      if (!mounted) return;
      if (bytes == null || bytes.isEmpty || !_canSaveSticker(message)) {
        messenger.showSnackBar(
          SnackBar(content: Text(l10n.stickerSaveFailed(l10n.unknownReason))),
        );
        return;
      }
      final mime = message.mediaMime.toLowerCase().startsWith('image/')
          ? message.mediaMime
          : (lookupMimeType(
                  message.mediaName.isNotEmpty
                      ? message.mediaName
                      : message.localPath,
                ) ??
                'image/png');
      final saved = await _vm.saveStickerImage(bytes, mime);
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(_stickerSaveLabel(saved))));
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.stickerSaveFailed('$e'))),
      );
    }
  }

  Future<void> _addStickerFromFile() async {
    if (_ui.pickingFile) return;
    _vm.setPickingFile(true);
    await WidgetsBinding.instance.endOfFrame;
    PlatformFile? picked;
    try {
      picked = await FilePicker.pickFile(type: FileType.image);
    } finally {
      _vm.setPickingFile(false);
    }
    if (!mounted || picked == null) return;
    final bytes = await picked.readAsBytes();
    if (!mounted || bytes.isEmpty) return;
    final mime = lookupMimeType(picked.name) ?? 'image/png';
    if (!isImageMime(mime, picked.name)) return;
    try {
      final saved = await _vm.saveStickerImage(bytes, mime);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(_stickerSaveLabel(saved))));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.stickerSaveFailed('$e'))),
      );
    }
  }

  Future<void> _sendSticker(Sticker sticker) async {
    if (_ui.sending) return;
    final result = await _vm.sendSticker(
      sticker,
      confirm: _confirm,
      l10n: context.l10n,
    );
    if (!mounted) return;
    if (result.uploadUnavailable) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.httpUploadUnavailable)),
      );
      return;
    }
    final error = result.error;
    if (error != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.l10n.uploadFailed(error))));
    } else if (result.failureReason != null) {
      _showNotSent(result.failureReason!);
    }
    if (result.queued || result.sent) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    }
  }

  Future<void> _attachFile() async {
    final ui = _ui;
    if (ui.sending || ui.pickingFile) return;
    // Button is disabled when upload is unavailable; keep this as a guard.
    if (!await _vm.isUploadAvailable()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.httpUploadUnavailable)),
      );
      return;
    }
    _vm.setPickingFile(true);
    // Paint the barrier before the native picker steals the next frame.
    await WidgetsBinding.instance.endOfFrame;
    PlatformFile? picked;
    try {
      // Single file; bytes via readAsBytes (works on web without a path).
      picked = await FilePicker.pickFile();
    } finally {
      _vm.setPickingFile(false);
    }
    if (!mounted || picked == null) return;
    final bytes = await picked.readAsBytes();
    if (!mounted || bytes.isEmpty) return;

    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(context.l10n.uploadingFile)));
    final result = await _vm.sendAttachmentBytes(
      bytes,
      fileName: picked.name,
      confirm: _confirm,
      l10n: context.l10n,
    );
    if (!mounted) return;
    final error = result.error;
    if (error != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.l10n.uploadFailed(error))));
    } else if (result.failureReason != null) {
      _showNotSent(result.failureReason!);
    }
    if (result.queued || result.sent) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    }
  }

  /// Upload a hold-to-talk clip (Telegram MediaController → sendMessage).
  Future<void> _sendVoice(VoiceClip clip) async {
    if (_ui.sending) return;
    if (!await _vm.isUploadAvailable()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.httpUploadUnavailable)),
      );
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(context.l10n.uploadingFile)));
    final result = await _vm.sendAttachmentBytes(
      clip.bytes,
      fileName: clip.fileName,
      confirm: _confirm,
      l10n: context.l10n,
      mimeOverride: clip.mime,
    );
    if (!mounted) return;
    final error = result.error;
    if (error != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.l10n.uploadFailed(error))));
    } else if (result.failureReason != null) {
      _showNotSent(result.failureReason!);
    }
    if (result.queued || result.sent) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    }
  }

  /// Conversations `highlightInConference`: tap an occupant avatar to address them.
  void _mentionOccupant(String nick) {
    if (nick.trim().isEmpty || _selectionMode || _editingId != null) return;
    final sel = _input.selection;
    // Avatar taps unfocus the field and invalidate selection — fall back to end.
    final start = sel.isValid ? sel.extentOffset : _input.text.length;
    final edit = _mentions.apply(
      text: _input.text,
      selectionStart: start,
      nick: nick,
      occupantNicks: [
        for (final o in _ui.room?.occupants ?? const <Occupant>[]) o.nick,
      ],
    );
    _input.value = TextEditingValue(
      text: edit.text,
      selection: TextSelection.collapsed(offset: edit.selection),
    );
    _vm.onInputChanged(edit.text);
    _focus.requestFocus();
  }

  /// Long-press on a group bubble avatar → same member sheet as room profile.
  ///
  /// Uses the *live* roster entry (Gajim). A historical message does not keep
  /// kick/voice available after the sender goes offline; affiliation actions
  /// still need a real JID on that live entry (or an offline affiliate stub).
  Future<void> _onOccupantAvatarLongPress(String nick) async {
    if (nick.trim().isEmpty || _selectionMode) return;
    final room = _ui.room;
    if (room == null || nick == room.nick) return;
    // Prefer live occupant; if they fully left (no offline stub), treat as
    // offline with unknown affiliation — no fabricated privileges.
    final occupant =
        occupantByNick(room, nick) ??
        Occupant(nick: nick, affiliation: 'none', role: 'none');
    final xmpp = resolveChatKey(widget.chatJid).session.xmpp;
    final caps = await xmpp.roomSelfCapabilities(room.roomJid);
    if (!mounted) return;
    final nav = await runOccupantActions(
      context: context,
      ref: ref,
      chatKey: widget.chatJid,
      room: room,
      occupant: occupant,
      caps: caps,
      xmpp: xmpp,
    );
    if (!mounted || nav == null) return;
    final jid = nav.privateChatJid;
    if (jid != null && jid.isNotEmpty) {
      final accountId = resolveChatKey(widget.chatJid).session.account.id;
      openChat(context, ChatRef(accountId: accountId, jid: jid).key);
      return;
    }
    final mucPm = nav.mucPmNick;
    if (mucPm != null && mucPm.isNotEmpty) {
      final effect = await _vm.applyMemberResult(
        roomJid: room.roomJid,
        leaving: false,
        destroyed: false,
        mucPmNick: mucPm,
      );
      if (!mounted) return;
      if (effect.kind == ChatMemberEffectKind.privateMessage) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _focus.requestFocus();
        });
      }
    }
  }

  Future<void> _send() async {
    if (_ui.sending) return;
    final raw = _input.text;
    if (raw.trim().isEmpty) return;

    // Take the composer's contents now, synchronously: the row is written to
    // the DB before any network work, and a second tap must find an empty
    // composer rather than queueing the same line twice.
    final reply = _replyingTo;
    if (reply != null) setState(() => _replyingTo = null);
    _input.clear();

    final body = await _prepareBodyForSend(raw);
    if (!mounted) return;
    if (body == null) {
      // Cancelled at the tracking prompt — put the draft back.
      _restoreUnsentDraft(raw, reply);
      return;
    }

    // The bubble goes up as soon as the row is written; the send itself only
    // reports back later (a failure notice, or nothing when it worked).
    _vm.onMessageSent();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    final result = await _vm.sendText(
      body,
      confirm: _confirm,
      l10n: context.l10n,
      reply: reply,
    );
    if (!mounted) return;
    final failure = result.failureReason;
    if (failure != null) _showNotSent(failure);

    // A socket failure keeps the bubble with STATUS_SEND_FAILED and does not
    // restore the text. Only a send the user cancelled at a track dialog left
    // no row behind, and that draft must come back.
    if (!result.queued && !result.sent) {
      _restoreUnsentDraft(body, reply);
      _showUnsentNotice();
    }
  }

  /// Pre-send tracking check. Returns body to send, or null if cancelled.
  Future<String?> _prepareBodyForSend(String raw) async {
    final enabled = await loadRemoveTrackingEnabled();
    if (!mounted) return null;
    if (!enabled) return raw;

    final untracker = Untracker(raw);
    if (!untracker.inspect()) return raw;

    final l10n = context.l10n;
    var canceled = false;
    BuildContext? checkingCtx;
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) {
          checkingCtx = ctx;
          return AlertDialog(
            content: Text(l10n.trackingChecking),
            actions: [
              TextButton(
                onPressed: () {
                  canceled = true;
                  Navigator.of(ctx).pop();
                },
                child: Text(l10n.cancel),
              ),
            ],
          );
        },
      ),
    );

    UntrackResult? cleaned;
    Object? error;
    try {
      cleaned = await untracker.untrack();
    } catch (e) {
      error = e;
    }
    if (!mounted) return null;
    final open = checkingCtx;
    if (open != null && open.mounted) Navigator.of(open).pop();
    if (canceled) return null;

    if (error != null) {
      // Tracking was detected (inspect) but network failed — still warn.
      final sendOriginal = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(l10n.trackingWarning),
          content: Text(l10n.trackingNetworkError),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l10n.cancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(l10n.trackingSendOriginal),
            ),
          ],
        ),
      );
      return sendOriginal == true ? raw : null;
    }

    final text = cleaned!.text;
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.trackingWarning),
        content: Text(l10n.trackingWarningDetected(text)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'original'),
            child: Text(l10n.trackingSendOriginal),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'cleaned'),
            child: Text(l10n.trackingSendSafely),
          ),
        ],
      ),
    );
    return switch (choice) {
      'original' => raw,
      'cleaned' => text,
      _ => null,
    };
  }

  /// Adds or withdraws [emoji] on the message addressed by [targetId].
  Future<void> _toggleReaction(String targetId, String emoji) async {
    final ok = await _vm.toggleReaction(targetId, emoji);
    if (ok || !mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(context.l10n.reactionSendFailed)));
  }

  Future<void> _showPinned() async {
    if (!mounted) return;
    final ids = await ref.read(pinnedIdsProvider(widget.chatJid).future);
    final bodies = await _vm.pinnedBodies(ids);
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) =>
          PinnedSheet(chatJid: widget.chatJid, pinnedIds: ids, bodies: bodies),
    );
  }

  /// Opens [ProfilePage] or [RoomProfilePage], same entry as tapping the header.
  Future<void> _openChatProfile() async {
    final ui = _ui;
    if (!ui.isGroup) {
      await Navigator.of(context)
          .pushNamed('/profile', arguments: widget.chatJid);
      return;
    }
    final chat = ui.room;
    if (chat == null) return;
    // About/subject lives on the room profile; AppBar subtitle stays member count.
    final result = await Navigator.of(
      context,
    ).pushNamed<RoomProfileResult>('/room-profile', arguments: widget.chatJid);
    if (!mounted || result == null) return;
    final effect = await _vm.applyMemberResult(
      roomJid: chat.roomJid,
      leaving: result.leaving,
      destroyed: result.destroyed,
      jid: result.jid,
      mucPmNick: result.mucPmNick,
    );
    if (!mounted) return;
    switch (effect.kind) {
      case ChatMemberEffectKind.left:
        if (result.destroyed) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(context.l10n.destroyRoomSucceeded)),
          );
        }
        if (widget.embedded) {
          clearSelectedChat(context);
        } else {
          unawaited(Navigator.of(context).maybePop());
        }
      case ChatMemberEffectKind.destroyFailed:
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.l10n.destroyRoomFailed)));
      case ChatMemberEffectKind.openChat:
        final accountId = resolveChatKey(widget.chatJid).session.account.id;
        openChat(context, ChatRef(accountId: accountId, jid: effect.jid!).key);
      case ChatMemberEffectKind.privateMessage:
        // Conversations privateMessageWith / nextCounterpart: stay in room UI.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _focus.requestFocus();
        });
      case ChatMemberEffectKind.none:
        break;
    }
  }

  /// Long-press on a message: the context menu, then whatever it leads to.
  Future<void> _showMessageMenu(
    Message message,
    String body,
    Rect anchor,
  ) async {
    if (!mounted) return;
    // Read before the dialog opens: an await here would leave a frame where a
    // tap lands on nothing, and the dialog is modal so the menu's own action
    // handler is the only thing that should be doing async work.
    final pinned = await _vm.isPinned(message.stanzaId);
    if (!mounted) return;
    final track = storedTrack(message.encMode);
    final isFileMessage =
        message.mediaUrl.isNotEmpty || message.localPath.isNotEmpty;
    final decrypted =
        message.encMode != EncModeToken.error.wire && !message.retracted;
    final actions = MessageActions.for_(
      mine: !message.incoming,
      moderate:
          _ui.canModerate &&
          message.incoming &&
          message.roomStanzaId.isNotEmpty,
      groupchat: _ui.isGroup,
      hasRoomStanzaId: message.roomStanzaId.isNotEmpty,
      retracted: message.retracted,
      // An undecryptable message has no body to copy or correct; offering
      // either would act on a placeholder.
      decrypted: decrypted,
      addressable: message.stanzaId.isNotEmpty,
      pinned: pinned,
      canSaveFile:
          !kIsWeb && isFileMessage && mediaStore.existsSync(message.localPath),
      canSaveSticker: _canSaveSticker(message),
      canCopySelection: !isFileMessage && body.trim().isNotEmpty && decrypted,
      canTranslate: canOfferTranslate(
        body: body,
        decrypted: decrypted,
        retracted: message.retracted,
        hasMedia: isFileMessage,
      ),
    );
    if (actions.isEmpty) return;

    if (actions.canCopySelection) {
      _selectedSlice = body;
      setState(() => _selectingMessageId = message.id);
    }
    final choice = await showMessageMenu(
      context,
      actions: actions,
      trackIsPlaintext: track == Track.none,
      anchor: anchor,
    );
    final slice = _selectedSlice;
    if (mounted && _selectingMessageId != null) {
      setState(() => _selectingMessageId = null);
    }
    if (!mounted || choice == null) return;

    switch (choice) {
      case MessageAction.reply:
        setState(() {
          _replyingTo = (
            id: message.stanzaId,
            body: body,
            author: message.incoming ? _peerJid : 'You',
          );
        });
        // The keyboard is what the user wants next; opening the composer
        // without it leaves them typing at nothing.
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _focus.requestFocus(),
        );
      case MessageAction.react:
        setState(() => _reactingToId = message.stanzaId);
      case MessageAction.copy:
        unawaited(_copyToClipboard(body));
      case MessageAction.copySelection:
        if (slice.isEmpty) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(context.l10n.nothingToCopy)));
          break;
        }
        unawaited(_copyToClipboard(slice));
      case MessageAction.translate:
        unawaited(_translateMessage(message, body));
      case MessageAction.select:
        _toggleSelected(message);
      case MessageAction.forward:
        await _forwardMessage(message, body);
      case MessageAction.saveFile:
        await _saveMessageFile(message);
      case MessageAction.saveSticker:
        await _saveMessageSticker(message);
      case MessageAction.pin:
        await _vm.togglePinned(message.stanzaId);
        if (mounted) setState(() {});
      case MessageAction.edit:
        setState(() {
          _editingId = message.stanzaId;
          _editingBody = body;
        });
      case MessageAction.retract:
        if (!await _confirmRetract()) return;
        await _doRetract(message);
    }
  }

  /// Fetches a translation and shows it under the bubble for this open chat.
  Future<void> _translateMessage(Message message, String body) async {
    final l10n = context.l10n;
    final cacheKey = message.stanzaId.isNotEmpty
        ? message.stanzaId
        : 'body:${body.hashCode}';
    if (_translations.containsKey(cacheKey)) {
      if (mounted) setState(() {});
      return;
    }
    final prefs = await TranslationPrefs.load();
    if (!mounted) return;
    if (!translationService.isConfigured(prefs)) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.translationNotConfigured)));
      return;
    }
    setState(() => _translating.add(cacheKey));
    try {
      final lang = Localizations.localeOf(context).languageCode;
      final result = await translationService.translateOnce(
        body,
        prefs: prefs,
        uiLanguageCode: lang,
      );
      if (!mounted) return;
      setState(() {
        _translations[cacheKey] = result.text;
        _translating.remove(cacheKey);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _translating.remove(cacheKey));
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.translationFailed('$e'))));
    }
  }

  Future<void> _copyToClipboard(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(context.l10n.copied)));
  }

  /// Copies a downloaded attachment out of the private media store.
  Future<void> _saveMessageFile(Message message) async {
    final l10n = context.l10n;
    final name = message.mediaName.isNotEmpty
        ? message.mediaName
        : (message.mediaUrl.isNotEmpty ? l10n.fileAttachment : 'file');
    final messenger = ScaffoldMessenger.of(context);
    try {
      final dest = await mediaStore.copyToPublic(
        message.localPath,
        mime: message.mediaMime,
        preferredName: name,
      );
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.fileSavedToPublic(dest))),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.couldNotSaveFile('$e'))),
      );
    }
  }

  /// Retracts [message]; the view model applies it locally only after the
  /// send succeeded.
  Future<void> _doRetract(Message message) async {
    final sent = await _vm.retractMessage(message.stanzaId);
    if (!mounted) return;
    if (!sent) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.couldNotRetractUnsent)),
      );
      return;
    }
    setState(() {});
  }

  /// Forwards [message] from this conversation into another one.
  Future<void> _forwardMessage(Message message, String body) async {
    if (!mounted) return;
    if (body.trim().isEmpty) return;
    // Single forward: plain body, no header / quote wrapper.
    final items = [
      ForwardItem(body: body, chatJid: _peerJid, preformatted: true),
    ];
    await _pickTargetAndForward(items, selectionCount: 1);
  }

  /// Sends a correction for [_editingId] and stores it.
  Future<void> _submitCorrection(String body) async {
    final targetId = _editingId;
    if (targetId == null) return;
    final failure = await _vm.submitCorrection(
      targetId,
      body,
      l10n: context.l10n,
    );
    if (!mounted) return;
    if (failure != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.notCorrected(failure))),
      );
      return;
    }
    setState(() {
      _editingId = null;
      _editingBody = '';
    });
  }

  /// Telegram caps multi-select at 100 (`ChatActivity` selection).
  static const _maxSelection = 100;

  /// Adds or removes [message] from the selection.
  ///
  /// A message with no addressable id cannot be forwarded or retracted, so it
  /// is not selectable at all — offering it would produce a selection the user
  /// cannot act on.
  void _toggleSelected(Message message) {
    if (message.stanzaId.isEmpty || message.retracted) return;
    final removing = _selection.contains(message.stanzaId);
    if (!removing && _selection.length >= _maxSelection) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.l10n.selectionLimitReached(_maxSelection)),
        ),
      );
      return;
    }
    setState(() {
      // Entering selection dismisses reply / edit / react chrome.
      if (_selection.isEmpty) {
        _replyingTo = null;
        _editingId = null;
        _editingBody = '';
        _reactingToId = null;
      }
      if (removing) {
        _selection.remove(message.stanzaId);
      } else {
        _selection.add(message.stanzaId);
      }
    });
  }

  void _clearSelection() => setState(_selection.clear);

  /// Copy selected messages as a quoted transcript.
  Future<void> _copySelection() async {
    if (_selection.isEmpty) return;
    final text = formatQuotedTranscript(
      _transcriptItemsForIds(_selection.toList()),
    );
    if (text.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(context.l10n.nothingToCopy)));
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(context.l10n.copied)));
    _clearSelection();
  }

  /// Forwards the selection: ask merge vs separate when more than one.
  Future<void> _forwardSelection() async {
    if (!mounted || _selection.isEmpty) return;
    final ids = List<String>.from(_selection);
    final transcriptItems = _transcriptItemsForIds(ids);
    if (transcriptItems.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(context.l10n.nothingToForward)));
      return;
    }

    final merge = transcriptItems.length == 1
        ? false // one message: same as separate (quote only, no header)
        : await _pickForwardMode();
    if (!mounted || merge == null) return;

    final List<ForwardItem> items;
    if (merge) {
      final text = formatQuotedTranscript(transcriptItems);
      items = [ForwardItem(body: text, chatJid: _peerJid, preformatted: true)];
    } else {
      // One forward per message: plain body (no header, no `>` quote).
      items = [
        for (final t in transcriptItems)
          ForwardItem(body: t.body, chatJid: _peerJid, preformatted: true),
      ];
    }
    final ok = await _pickTargetAndForward(
      items,
      selectionCount: transcriptItems.length,
    );
    if (ok && mounted) _clearSelection();
  }

  /// `true` = merge, `false` = separate, `null` = cancelled.
  Future<bool?> _pickForwardMode() {
    final l10n = context.l10n;
    return showModalBottomSheet<bool>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.merge_type),
              title: Text(l10n.forwardMerged),
              subtitle: Text(l10n.forwardMergedSummary),
              onTap: () => Navigator.pop(ctx, true),
            ),
            ListTile(
              leading: const Icon(Icons.view_agenda_outlined),
              title: Text(l10n.forwardSeparately),
              subtitle: Text(l10n.forwardSeparatelySummary),
              onTap: () => Navigator.pop(ctx, false),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// Shows the target picker and sends. Returns whether the forward finished OK.
  Future<bool> _pickTargetAndForward(
    List<ForwardItem> items, {
    required int selectionCount,
  }) async {
    if (!mounted || items.isEmpty) return false;
    final target = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) =>
          ForwardTargetSheet(items: items, selectionCount: selectionCount),
    );
    if (target == null || !mounted) return false;
    final messenger = ScaffoldMessenger.of(context);
    final l10n = context.l10n;
    final result = await _vm.forwardToChat(items: items, targetKey: target);
    final destPeer = result.destPeer;
    if (result.blocked) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.unblockBeforeForward(destPeer))),
      );
      return false;
    }
    final outcome = result.outcome;
    if (outcome == null) return false;
    if (!outcome.ok) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            l10n.forwardedPartialThenStopped(
              outcome.forwarded,
              items.length,
              destPeer,
            ),
          ),
        ),
      );
      return false;
    }
    messenger.showSnackBar(SnackBar(content: Text(l10n.forwardedTo(destPeer))));
    return true;
  }

  List<QuotedTranscriptItem> _transcriptItemsForIds(List<String> ids) {
    final list =
        ref.read(messagesProvider(widget.chatJid)).value ?? const <Message>[];
    final byId = {for (final m in list) m.stanzaId: m};
    final out = <QuotedTranscriptItem>[];
    for (final id in ids) {
      final m = byId[id];
      if (m == null || m.retracted || m.body.trim().isEmpty) continue;
      out.add(_transcriptItemFor(m));
    }
    return out;
  }

  QuotedTranscriptItem _transcriptItemFor(Message m) {
    final isGroup = _ui.isGroup;
    final storedTitle =
        ref.read(chatProvider(widget.chatJid)).value?.title ?? '';
    final peerLabel = displayName(
      localNickname: null,
      rosterTitle: storedTitle,
      roomTitle: isGroup ? storedTitle : '',
      jid: _peerJid,
      isRoom: isGroup,
    );
    return QuotedTranscriptItem(
      id: m.stanzaId,
      body: m.body,
      timestamp: m.timestamp,
      senderKey: m.incoming ? m.sender : '__me__',
      senderLabel: m.incoming
          ? (isGroup ? (occupantNick(m.sender) ?? m.sender) : peerLabel)
          : _transcriptSelfLabel(),
    );
  }

  String _transcriptSelfLabel() {
    final account = accountHub.primarySession?.account;
    final nick = account?.displayName.trim() ?? '';
    if (nick.isNotEmpty) return nick;
    final jid = ref.read(xmppServiceProvider).myJid ?? '';
    final local = jid.split('@').first;
    return local.isNotEmpty ? local : 'me';
  }

  /// Asks before a retraction. Gajim does the same: it cannot be undone, and
  /// it is not a guaranteed removal.
  Future<bool> _confirmRetract() async {
    final l10n = context.l10n;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.retractConfirmTitle),
        content: Text(l10n.retractConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.retractMessage),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  /// Retracts the selected messages that we sent.
  Future<void> _deleteSelection() async {
    if (!mounted) return;
    if (!await _confirmRetract()) return;
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final result = await _vm.deleteMineByIds(List<String>.from(_selection));
    if (!mounted) return;
    final l10n = context.l10n;
    if (result.mine == 0) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.onlyOwnMessagesRetractable)),
      );
      return;
    }
    if (result.deleted < result.mine) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(l10n.retractedPartial(result.deleted, result.mine)),
        ),
      );
    }
    _clearSelection();
  }

  void _showUnsentNotice() {
    _showNotice(context.l10n.messageNotSentSnack);
  }

  /// Puts a draft back after a send that never reached the DB.
  ///
  /// The composer is emptied up front (so the bubble can appear at once), so
  /// anything that stops the send before the row is written has to undo that —
  /// text and the reply-quote it was going to carry.
  void _restoreUnsentDraft(
    String text,
    ({String id, String body, String author})? reply,
  ) {
    if (!mounted) return;
    setState(() {
      if (_input.text.isEmpty) _input.text = text;
      if (reply != null && _replyingTo == null) _replyingTo = reply;
    });
  }

  Future<void> _loadHistory() async {
    final count = await _vm.loadHistory();
    if (!mounted) return;
    final l10n = context.l10n;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          count == null
              ? l10n.couldNotLoadHistory
              : l10n.loadedArchivedMessages(count),
        ),
      ),
    );
  }

  /// Appearance is per chat, so the sheet writes on every change rather than on
  /// dismissal: the swatches are the preview, and waiting for "done" would mean
  /// choosing blind.
  void _openAppearance() {
    final appearance =
        ref.read(chatAppearanceProvider(widget.chatJid)).value ??
        const ChatAppearance();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => AppearancePicker(
        chatJid: _peerJid,
        initial: appearance,
        onChanged: (next) =>
            unawaited(setChatAppearance(ref, widget.chatJid, next)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tg = context.tg;
    final l10n = context.l10n;
    final ui = ref.watch(chatViewModelProvider(widget.chatJid));
    final messages = ref.watch(messagesProvider(widget.chatJid));
    // The chosen track, not the negotiated one. The header says what the user
    // picked; whether it can actually be used is decided at send time and
    // explained there if not.
    final track = ui.isGroup && !ui.mucEncryptable
        ? Track.none
        : ref.watch(chatTrackProvider(widget.chatJid)).value ?? Track.standard;
    final appearance =
        ref.watch(chatAppearanceProvider(widget.chatJid)).value ??
        const ChatAppearance();
    final backgroundEpoch = ref.watch(chatRowRevisionProvider);
    final attachEnabled = ref.watch(httpUploadAvailableProvider).value ?? false;
    final chatRow = ref.watch(chatProvider(widget.chatJid)).value;
    final storedTitle = chatRow?.title ?? '';
    final title = displayName(
      localNickname: null,
      rosterTitle: storedTitle,
      roomTitle: ui.isGroup ? storedTitle : '',
      jid: _peerJid,
      isRoom: ui.isGroup,
    );
    // Watched so a draft saved here is read back into the field; see
    // _restoreDraft for why it only happens once.
    ref.watch(draftProvider(widget.chatJid));
    _restoreDraft();

    // Telegram ChatActivity action mode: back clears selection instead of
    // leaving the chat.
    return PopScope(
      canPop: !_selectionMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _selectionMode) _clearSelection();
      },
      child: Stack(
        children: [
          Scaffold(
            appBar: AppBar(
              titleSpacing: _selectionMode ? null : 0,
              automaticallyImplyLeading: !widget.embedded && !_selectionMode,
              leading: _selectionMode
                  ? IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: l10n.cancel,
                      onPressed: _clearSelection,
                    )
                  : null,
              // Telegram createActionMode: count title + bulk actions.
              title: _selectionMode
                  ? Text(l10n.selectedCount(_selection.length))
                  : Row(
                      children: [
                        GestureDetector(
                          onTap: _openChatProfile,
                          behavior: HitTestBehavior.opaque,
                          child: ContactAvatar(
                            jid: _peerJid,
                            title: title,
                            radius: TgDimens.avatarChat / 2,
                            hero: true,
                            showPresence: !ui.isGroup,
                            presence: ui.isGroup
                                ? null
                                : ref
                                      .watch(
                                        contactPresenceProvider(widget.chatJid),
                                      )
                                      .value
                                      ?.show,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: GestureDetector(
                            onTap: _openChatProfile,
                            behavior: HitTestBehavior.opaque,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                Text(
                                  ui.isGroup
                                      ? (ui.room == null
                                            ? l10n.joining
                                            : _roomMembersSubtitle(
                                                l10n,
                                                ui.room!,
                                              ))
                                      : _peerStatusSubtitle(
                                          context,
                                          ui.peerTyping,
                                          presence: ref
                                              .watch(
                                                contactPresenceProvider(
                                                  widget.chatJid,
                                                ),
                                              )
                                              .value,
                                        ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: TgDimens.timeFontSize,
                                    fontWeight: FontWeight.w400,
                                    color: Colors.white70,
                                    fontStyle:
                                        !ui.isGroup &&
                                            (ui.peerTyping ==
                                                    TypingState.composing ||
                                                ui.peerTyping ==
                                                    TypingState.paused)
                                        ? FontStyle.italic
                                        : FontStyle.normal,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
              actions: _selectionMode
                  ? [
                      IconButton(
                        icon: const Icon(Icons.copy),
                        tooltip: l10n.copyText,
                        onPressed: _copySelection,
                      ),
                      IconButton(
                        icon: const Icon(Icons.forward),
                        tooltip: l10n.forward,
                        onPressed: _forwardSelection,
                      ),
                      IconButton(
                        icon: const Icon(Icons.undo),
                        tooltip: l10n.retractMine,
                        onPressed: _deleteSelection,
                      ),
                    ]
                  : [
                      if (!ui.isGroup || ui.mucEncryptable)
                        EncBadge(
                          label: track.label,
                          locked: track != Track.none,
                          onTap: () =>
                              showTrackPicker(context, ref, widget.chatJid),
                        ),
                      IconButton(
                        icon: const Icon(Icons.search),
                        tooltip: l10n.searchInChat,
                        onPressed: _openInChatSearch,
                      ),
                      IconButton(
                        icon: const Icon(Icons.palette_outlined),
                        tooltip: l10n.appearance,
                        onPressed: _openAppearance,
                      ),
                      IconButton(
                        icon: const Icon(Icons.push_pin_outlined),
                        tooltip: l10n.pinnedMessages,
                        onPressed: _showPinned,
                      ),
                    ],
            ),
            body: BackdropGroup(
              // One blurred snapshot of the transcript, shared by the composer
              // island (see `GlassPanel`).
              child: Stack(
                children: [
                  ChatWallpaper(
                    chatJid: _peerJid,
                    appearance: appearance,
                    base: tg.pageBackground,
                    // Theme accent tints the pattern (per-chat colour was
                    // removed; the app theme colour already covers that).
                    accent: tg.accent,
                    imageEpoch: backgroundEpoch,
                    child: const SizedBox.expand(),
                  ),
                  Positioned.fill(
                    child: Column(
                      children: [
                        // Rooms are not roster contacts — no subscription banner.
                        if (!ui.isGroup)
                          ChatSubscriptionBanner(chatJid: widget.chatJid),
                        if (ui.advice != null)
                          TrackAdviceBanner(
                            advice: ui.advice!,
                            onSwitch: _vm.adoptAdvice,
                            onDismiss: _vm.dismissAdvice,
                          ),
                        Expanded(
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              messages.when(
                                data: (list) {
                                  if (list.isNotEmpty) _ensureInitialScroll();
                                  return ChatMessageList(
                                    chatKey: widget.chatJid,
                                    messages: list,
                                    scroll: _scroll,
                                    onRetryDecrypt: () => _loadHistory(),
                                    onReact: _toggleReaction,
                                    onMenu: _showMessageMenu,
                                    onToggleSelected: _toggleSelected,
                                    selectingMessageId: _selectingMessageId,
                                    onTextSelectionChanged: (slice) {
                                      _selectedSlice = slice;
                                    },
                                    onMentionNick: _mentionOccupant,
                                    onOccupantAvatarLongPress: (nick) =>
                                        unawaited(
                                          _onOccupantAvatarLongPress(nick),
                                        ),
                                    selectionMode: _selectionMode,
                                    selectedIds: _selection,
                                    translations: _translations,
                                    translatingIds: _translating,
                                    readAt: ref
                                        .watch(
                                          chatLastReadProvider(widget.chatJid),
                                        )
                                        .value,
                                    unreadCount: _unreadCountHere ?? 0,
                                    unreadDividerKey: _unreadDividerKey,
                                    focusMessageAnchor: _activeFocusAnchor,
                                    focusMessageKey: _focusMessageKey,
                                    bubbleStyle: appearance.bubble,
                                    isGroup: ui.isGroup,
                                    room: ui.room,
                                    highlightNicks: highlightNicksFor(
                                      mucNick: ui.mucNick,
                                      chatKey: widget.chatJid,
                                    ),
                                    peerName: title,
                                    selfNick: ui.mucNick,
                                  );
                                },
                                loading: () => const Center(
                                  child: CircularProgressIndicator(),
                                ),
                                error: (e, _) => Center(child: Text('$e')),
                              ),
                              if (ui.isGroup &&
                                  (ui.room?.subject?.trim().isNotEmpty ??
                                      false))
                                Positioned(
                                  top: 6,
                                  left: 10,
                                  right: 10,
                                  child: ChatTopicBanner(
                                    chatJid: widget.chatJid,
                                    subject: ui.room!.subject!.trim(),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        // Editing replaces the input bar rather than sitting above it: two
                        // text fields in one chat is ambiguous about which one a keystroke
                        // goes to.
                        if (ui.mucPmNick != null)
                          Material(
                            color: tg.accent.withValues(alpha: 0.12),
                            child: ListTile(
                              dense: true,
                              leading: Icon(
                                Icons.lock_outline,
                                color: tg.accent,
                                size: 20,
                              ),
                              title: Text(
                                l10n.privateMessageTo(ui.mucPmNick!),
                                style: TextStyle(
                                  color: tg.accent,
                                  fontSize: 13,
                                ),
                              ),
                              trailing: IconButton(
                                icon: const Icon(Icons.close, size: 18),
                                tooltip: l10n.cancel,
                                onPressed: () => _vm.setMucPmNick(null),
                              ),
                            ),
                          ),
                        if (_replyingTo != null && _editingId == null)
                          ReplyPreview(
                            author: _replyingTo!.author,
                            body: _replyingTo!.body,
                            onCancel: () => setState(() => _replyingTo = null),
                          ),
                        if (_notice != null)
                          _ChatNoticeBanner(
                            message: _notice!.message,
                            onDetails: _notice!.onDetails,
                            onDismiss: _clearNotice,
                          ),
                        // Selection actions live in the AppBar (Telegram action mode).
                        // The composer stays hidden so keystrokes cannot go to a draft
                        // while the user is picking messages.
                        if (_selectionMode)
                          const SizedBox.shrink()
                        else if (_editingId != null)
                          EditComposer(
                            initialText: _editingBody,
                            onSubmit: _submitCorrection,
                            onCancel: () => setState(() {
                              _editingId = null;
                              _editingBody = '';
                            }),
                          )
                        else
                          ChatInputBar(
                            controller: _input,
                            focusNode: _focus,
                            onChanged: _vm.onInputChanged,
                            onSend: _send,
                            onAttach: _attachFile,
                            onVoice: _sendVoice,
                            onStickers: _toggleStickers,
                            stickersOpen: _stickersOpen,
                            attachEnabled: attachEnabled,
                          ),
                        if (_stickersOpen &&
                            !_selectionMode &&
                            _editingId == null)
                          SizedBox(
                            height: 280,
                            child: StickerPanel(
                              stickers: _stickers ?? const Stream.empty(),
                              onInsert: _insertStickerText,
                              onSend: (sticker) =>
                                  unawaited(_sendSticker(sticker)),
                              onAdd: () => unawaited(_addStickerFromFile()),
                              onDelete: (sticker) =>
                                  unawaited(_vm.deleteSticker(sticker.id)),
                            ),
                          ),
                        if (_reactingToId != null)
                          QuickReactionBar(
                            emoji: kQuickReactions,
                            onPicked: (emoji) {
                              final target = _reactingToId;
                              setState(() => _reactingToId = null);
                              if (target != null) {
                                unawaited(_toggleReaction(target, emoji));
                              }
                            },
                            onDismissed: () =>
                                setState(() => _reactingToId = null),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            // Two different destinations, so two different affordances. Scrolling to
            // the bottom is "show me what just happened"; jumping to the first unread
            // is "show me what I missed". Collapsing them means the user who scrolled
            // up to find an older message cannot get back to the new ones in one tap.
            floatingActionButton: _selectionMode || _atBottom
                ? null
                : _scrollButton(tg),
          ),
          // Covers app bar, transcript, FAB, and input while the OS picker is up
          // so nothing behind it can be tapped or scrolled.
          if (ui.pickingFile)
            const ModalBarrier(dismissible: false, color: Color(0x66000000)),
        ],
      ),
    );
  }

  /// The scroll button, which is one of two things depending on whether there is
  /// anything unread.
  Widget _scrollButton(TgColors tg) {
    final l10n = context.l10n;
    final unread = _unreadCountHere ?? 0;
    final hasUnreadDivider =
        unread > 0 && _unreadDividerKey.currentContext != null;
    return FloatingActionButton.small(
      backgroundColor: hasUnreadDivider ? tg.accent : tg.peerBubble,
      // White on the accent, and the accent on the pale bubble: both pairs are
      // legible, and the colour difference is what tells the two states apart
      // without reading the icon.
      foregroundColor: hasUnreadDivider ? Colors.white : tg.accent,
      tooltip: hasUnreadDivider ? l10n.jumpToFirstUnread : l10n.scrollToLatest,
      onPressed: hasUnreadDivider ? () => _jumpToUnread() : _scrollToBottom,
      child: Icon(
        hasUnreadDivider
            ? Icons.keyboard_double_arrow_up
            : Icons.keyboard_arrow_down,
      ),
    );
  }
}

/// Inline transient notice shown above the composer.
///
/// A fixed [SnackBar] is laid out by the [Scaffold] at the bottom of the body
/// and does not avoid the floating input island, so it covers the composer it
/// is warning about. This banner lives in the body column above the island, so
/// it can never hide the field, and is dismissed by hand or by its timer.
class _ChatNoticeBanner extends StatelessWidget {
  const _ChatNoticeBanner({
    required this.message,
    required this.onDismiss,
    this.onDetails,
  });

  final String message;
  final VoidCallback onDismiss;
  final VoidCallback? onDetails;

  @override
  Widget build(BuildContext context) {
    final tg = context.tg;
    final l10n = context.l10n;
    return Material(
      color: tg.danger.withValues(alpha: 0.12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          children: [
            Icon(Icons.error_outline, size: 18, color: tg.danger),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: TextStyle(fontSize: 13, color: tg.textPrimary),
              ),
            ),
            if (onDetails != null)
              TextButton(onPressed: onDetails, child: Text(l10n.details)),
            IconButton(
              onPressed: onDismiss,
              icon: const Icon(Icons.close, size: 18),
              tooltip: l10n.dismiss,
              color: tg.textSecondary,
            ),
          ],
        ),
      ),
    );
  }
}
