// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Chat page. Layout and interactions follow Telegram for Android's
// `ChatActivity` (GPL-2.0-or-later), translated to Flutter.

import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:moxxmpp/moxxmpp.dart' show JID;

import '../../account/chat_ref.dart';
import '../../account/resolve.dart';
import '../../l10n/l10n.dart';
import '../../omemo/track.dart';
import '../../platform/media_store.dart';
import '../../state/providers.dart';
import '../../store/database.dart';
import '../../xmpp/connection.dart';
import '../../xmpp/forwarding.dart';
import '../../xmpp/local_nickname.dart';
import '../../xmpp/reactions.dart';
import '../contact_avatar.dart';
import '../../utils/appearance.dart';
import 'message_actions.dart';
import '../home/open_chat.dart';
import '../room/room_sheet.dart';
import '../chats/search.dart';
import 'message_bubble.dart';
import 'track_dialogs.dart';
import 'chat_viewmodel.dart';
import '../theme.dart';
import '../chats/unread.dart';

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

  /// Only for handing to the room sheet; all domain work goes through [_vm].
  XmppService get _xmpp => resolveChatKey(widget.chatJid).session.xmpp;

  /// Domain logic and UI state live in the view model; this State keeps only
  /// what needs a `BuildContext` or a widget controller.
  late ChatViewModel _vm;
  StreamSubscription<String>? _failureNoticeSub;
  StreamSubscription<String>? _noticeSub;

  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _focus = FocusNode();

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

  /// Id of the message whose quick-reaction strip is open, or null.
  String? _reactingToId;

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
      // Groupchat does not use 1:1 displayed markers the same way.
      if (!_ui.isGroup) unawaited(_vm.sendDisplayedForLatest());
    });
  }

  /// Attaches to the view model for [ChatPage.chatJid]: the provider build
  /// starts its subscriptions; here we only listen for what needs a snackbar.
  void _bindViewModel() {
    _vm = ref.read(chatViewModelProvider(widget.chatJid).notifier);
    _failureNoticeSub?.cancel();
    _noticeSub?.cancel();
    _failureNoticeSub = _vm.failureNotices.listen(_onFailureNotice);
    _noticeSub = _vm.notices.listen((text) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    });
  }

  @override
  void didUpdateWidget(ChatPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Each conversation has its own view model (advice, typing and room state
    // included), so switching chats just means attaching to the new one.
    if (oldWidget.chatJid != widget.chatJid) _bindViewModel();
  }

  void _onFailureNotice(String reason) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Not delivered: $reason'),
        action: SnackBarAction(
          label: 'Details',
          onPressed: () => _showRefusalHelp(reason),
        ),
      ),
    );
  }

  /// Turns the server's error into something actionable.
  ///
  /// `auth/forbidden` in practice means the server refuses stanzas outside a
  /// mutual subscription, which is the single most common reason a fresh
  /// contact sees every message silently vanish.
  void _showRefusalHelp(String reason) {
    final mutual = ref.read(contactStateProvider(widget.chatJid)).value;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Message not delivered'),
        content: Text(
          'The server refused this message:\n\n$reason\n\n'
          '${(mutual?.isMutual ?? false) ? '' : 'This contact is not a '
                    'mutual subscription yet (currently ${mutual?.summary ?? 'unknown'}). '
                    'Many servers refuse messages until both sides have accepted '
                    'each other.\n\n'}'
          'Ask them to accept your contact request, or wait for the other '
          'side to accept yours.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
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
    _scroll
      ..removeListener(_onScroll)
      ..dispose();
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// AppBar subtitle: peer typing (Conversations contact_is_typing) or track.
  String _peerStatusSubtitle(
    BuildContext context,
    Track track,
    TypingState peerTyping,
  ) {
    // Prefer a short local name when the JID is long.
    final name = _peerJid.split('@').first;
    final l10n = context.l10n;
    return switch (peerTyping) {
      TypingState.composing => l10n.contactIsTyping(name),
      TypingState.paused => l10n.contactStoppedTyping(name),
      TypingState.inactive => track.description.split(' — ').first,
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
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('Not sent: $reason')));
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
    );
    if (!mounted) return;
    final error = result.error;
    if (error != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.l10n.uploadFailed(error))));
    } else if (result.failureReason != null) {
      _showNotSent(result.failureReason!);
    } else if (result.sent) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    }
  }

  Future<void> _send() async {
    if (_ui.sending) return;
    final result = await _vm.sendText(
      _input.text,
      confirm: _confirm,
      reply: _replyingTo,
    );
    if (!mounted) return;
    final failure = result.failureReason;
    if (failure != null) _showNotSent(failure);

    if (result.sent) {
      if (_replyingTo != null) setState(() => _replyingTo = null);
      _input.clear();
      _vm.onMessageSent();
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    } else if (_input.text.trim().isNotEmpty) {
      // The text stays in the box. It was never sent, and a user who typed a
      // message and watched the box empty has no way to know what happened.
      _showUnsentNotice();
    }
  }

  /// Adds or withdraws [emoji] on the message addressed by [targetId].
  Future<void> _toggleReaction(String targetId, String emoji) async {
    final ok = await _vm.toggleReaction(targetId, emoji);
    if (ok || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Reaction could not be sent.')),
    );
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

  Future<void> _showMembers() async {
    final ui = _ui;
    final chat = ui.room;
    if (chat == null) return;
    // Telegram ChatAvatarContainer → Profile: about/subject lives in the
    // room sheet, not as AppBar subtitle (subtitle stays member count).
    final caps = await _xmpp.roomSelfCapabilities(chat.roomJid);
    if (!mounted) return;
    final result = await showRoomSheet(
      context,
      chat,
      chatKey: widget.chatJid,
      xmpp: _xmpp,
      caps: caps,
      canChangeSubject: ui.canChangeSubject || caps.canChangeSubject,
      onSetSubject: (subject) =>
          _xmpp.setGroupChatSubject(chat.roomJid, subject),
    );
    if (!mounted || result == null) return;
    final effect = await _vm.applyMemberResult(
      roomJid: chat.roomJid,
      leaving: result.leaving,
      jid: result.jid,
      mucPmNick: result.mucPmNick,
    );
    if (!mounted) return;
    switch (effect.kind) {
      case ChatMemberEffectKind.left:
        if (widget.embedded) {
          clearSelectedChat(context);
        } else {
          unawaited(Navigator.of(context).maybePop());
        }
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
  Future<void> _showMessageMenu(Message message, String body) async {
    if (!mounted) return;
    // Read before the dialog opens: an await here would leave a frame where a
    // tap lands on nothing, and the dialog is modal so the menu's own action
    // handler is the only thing that should be doing async work.
    final pinned = await _vm.isPinned(message.stanzaId);
    if (!mounted) return;
    final track = storedTrack(message.encMode);
    final isFileMessage =
        message.mediaUrl.isNotEmpty || message.localPath.isNotEmpty;
    final actions = MessageActions.for_(
      mine: !message.incoming,
      retracted: message.retracted,
      // An undecryptable message has no body to copy or correct; offering
      // either would act on a placeholder.
      decrypted:
          message.encMode != EncModeToken.error.wire && !message.retracted,
      addressable: message.stanzaId.isNotEmpty,
      pinned: pinned,
      canSaveFile:
          !kIsWeb && isFileMessage && mediaStore.existsSync(message.localPath),
    );
    if (actions.isEmpty) return;

    final choice = await showMessageMenu(
      context,
      actions: actions,
      trackIsPlaintext: track == Track.none,
    );
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
        unawaited(
          Clipboard.setData(ClipboardData(text: body)).then((_) {
            if (!mounted) return;
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text(context.l10n.copied)));
          }),
        );
      case MessageAction.forward:
        await _forwardMessage(message, body);
      case MessageAction.saveFile:
        await _saveMessageFile(message);
      case MessageAction.pin:
        await _vm.togglePinned(message.stanzaId);
        if (mounted) setState(() {});
      case MessageAction.edit:
        setState(() {
          _editingId = message.stanzaId;
          _editingBody = body;
        });
      case MessageAction.retract:
        await _doRetract(message);
    }
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
        const SnackBar(
          content: Text('Could not delete: the message was not sent.'),
        ),
      );
      return;
    }
    setState(() {});
  }

  /// Forwards [body] from this conversation into another one.
  Future<void> _forwardMessage(Message message, String body) async {
    if (!mounted) return;
    final items = [ForwardItem(body: body, chatJid: _peerJid)];
    final target = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => ForwardTargetSheet(items: items),
    );
    if (target == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final result = await _vm.forwardToChat(items: items, targetKey: target);
    final destPeer = result.destPeer;
    if (result.blocked) {
      messenger.showSnackBar(
        SnackBar(content: Text('Unblock $destPeer before forwarding to them.')),
      );
      return;
    }
    final outcome = result.outcome;
    if (outcome == null) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          outcome.ok
              ? 'Forwarded to $destPeer'
              : 'Forwarded ${outcome.forwarded}, then stopped: the $destPeer '
                    'track cannot be used right now.',
        ),
      ),
    );
    if (!mounted) return;
    if (outcome.ok) navigator.pop();
  }

  /// Sends a correction for [_editingId] and stores it.
  Future<void> _submitCorrection(String body) async {
    final targetId = _editingId;
    if (targetId == null) return;
    final failure = await _vm.submitCorrection(targetId, body);
    if (!mounted) return;
    if (failure != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Not corrected: $failure')));
      return;
    }
    setState(() {
      _editingId = null;
      _editingBody = '';
    });
  }

  /// Adds or removes [message] from the selection.
  ///
  /// A message with no addressable id cannot be forwarded or retracted, so it
  /// is not selectable at all — offering it would produce a selection the user
  /// cannot act on.
  void _toggleSelected(Message message) {
    if (message.stanzaId.isEmpty || message.retracted) return;
    setState(() {
      if (_selection.contains(message.stanzaId)) {
        _selection.remove(message.stanzaId);
      } else {
        _selection.add(message.stanzaId);
      }
    });
  }

  /// Forwards everything selected, in the order it was picked.
  Future<void> _forwardSelection() async {
    if (!mounted) return;
    final items = await _vm.forwardItemsFor(List<String>.from(_selection));
    if (!mounted) return;
    if (items.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nothing there to forward.')),
      );
      return;
    }
    final target = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => ForwardTargetSheet(items: items),
    );
    if (target == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final result = await _vm.forwardToChat(items: items, targetKey: target);
    final destPeer = result.destPeer;
    if (result.blocked) {
      messenger.showSnackBar(
        SnackBar(content: Text('Unblock $destPeer before forwarding to them.')),
      );
      return;
    }
    final outcome = result.outcome;
    if (outcome == null) return;
    if (!outcome.ok && mounted) {
      // Partial forwards are reported rather than silently dropped: the user
      // is the only one who knows which of the selected messages mattered.
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Forwarded ${outcome.forwarded} of ${items.length}, then stopped: '
            'the $destPeer track cannot be used right now.',
          ),
        ),
      );
      return;
    }
    if (mounted) setState(_selection.clear);
  }

  /// Retracts the selected messages that we sent.
  Future<void> _deleteSelection() async {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final result = await _vm.deleteMineByIds(List<String>.from(_selection));
    if (!mounted) return;
    if (result.mine == 0) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Only your own messages can be deleted.')),
      );
      return;
    }
    if (result.deleted < result.mine) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Deleted ${result.deleted} of ${result.mine}; the rest could not '
            'be sent.',
          ),
        ),
      );
    }
    setState(_selection.clear);
  }

  void _showUnsentNotice() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(context.l10n.messageNotSentSnack),
        duration: const Duration(seconds: 4),
      ),
    );
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
    final attachEnabled = ref.watch(httpUploadAvailableProvider).value ?? false;
    final chatRow = ref.watch(chatProvider(widget.chatJid)).value;
    final title = displayName(
      localNickname: null,
      rosterTitle: chatRow?.title ?? '',
      jid: _peerJid,
      isRoom: ui.isGroup,
    );
    // Watched so a draft saved here is read back into the field; see
    // _restoreDraft for why it only happens once.
    ref.watch(draftProvider(widget.chatJid));
    _restoreDraft();

    return Stack(
      children: [
        Scaffold(
          appBar: AppBar(
            titleSpacing: 0,
            automaticallyImplyLeading: !widget.embedded,
            // Telegram ChatAvatarContainer: one tap target → profile/room sheet.
            // Group subtitle is member count (getChatSubtitle), not about/subject.
            title: GestureDetector(
              onTap: ui.isGroup
                  ? _showMembers
                  : () =>
                        Navigator.of(context)
                            .pushNamed('/profile', arguments: widget.chatJid),
              behavior: HitTestBehavior.opaque,
              child: Row(
                children: [
                  ui.isGroup
                      ? CircleAvatar(
                          radius: TgDimens.avatarChat / 2,
                          backgroundColor: tg.accent.withValues(alpha: 0.18),
                          child: Icon(
                            Icons.groups_outlined,
                            color: tg.accent,
                            size: TgDimens.avatarChat * 0.55,
                          ),
                        )
                      : ContactAvatar(
                          jid: _peerJid,
                          title: title,
                          radius: TgDimens.avatarChat / 2,
                          hero: true,
                        ),
                  const SizedBox(width: 10),
                  Expanded(
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
                                    : l10n.membersInRoom(
                                        ui.room!.occupants.length,
                                      ))
                              : _peerStatusSubtitle(
                                  context,
                                  track,
                                  ui.peerTyping,
                                ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: TgDimens.timeFontSize,
                            fontWeight: FontWeight.w400,
                            color: Colors.white70,
                            fontStyle:
                                !ui.isGroup &&
                                    (ui.peerTyping == TypingState.composing ||
                                        ui.peerTyping == TypingState.paused)
                                ? FontStyle.italic
                                : FontStyle.normal,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              if (!ui.isGroup || ui.mucEncryptable)
                EncBadge(
                  label: track.label,
                  locked: track != Track.none,
                  onTap: () => showTrackPicker(context, ref, widget.chatJid),
                ),
              if (ui.isGroup)
                IconButton(
                  icon: const Icon(Icons.group_outlined),
                  tooltip: l10n.members,
                  onPressed: _showMembers,
                ),
              IconButton(
                icon: const Icon(Icons.search),
                tooltip: l10n.searchInChat,
                onPressed: _openInChatSearch,
              ),
              IconButton(
                icon: const Icon(Icons.palette_outlined),
                tooltip: l10n.appearance,
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  builder: (sheetContext) => AppearancePicker(
                    initial: appearance,
                    // Written on every change rather than on dismissal: the swatches
                    // are the preview, and waiting for "done" would mean choosing
                    // blind.
                    onChanged: (next) =>
                        unawaited(setChatAppearance(ref, widget.chatJid, next)),
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.push_pin_outlined),
                tooltip: l10n.pinnedMessages,
                onPressed: _showPinned,
              ),
              IconButton(
                icon: const Icon(Icons.history),
                tooltip: l10n.loadHistoryMam,
                onPressed: _loadHistory,
              ),
            ],
          ),
          body: Column(
            children: [
              // Rooms are not roster contacts — no subscription banner.
              if (!ui.isGroup) _SubscriptionBanner(chatJid: widget.chatJid),
              if (ui.advice != null)
                TrackAdviceBanner(
                  advice: ui.advice!,
                  onSwitch: _vm.adoptAdvice,
                  onDismiss: _vm.dismissAdvice,
                ),
              Expanded(
                child: Container(
                  color: tg.pageBackground,
                  // Painted inside the Expanded rather than behind the Scaffold,
                  // so the pattern does not also sit under the app bar and the input
                  // bar — Telegram draws it only behind the transcript.
                  child: CustomPaint(
                    painter: WallpaperPainter(
                      wallpaper: appearance.wallpaper,
                      base: tg.pageBackground,
                      // A per-conversation accent tints the pattern; without one it
                      // falls back to the theme's, so the pattern is never drawn in
                      // a colour the app does not otherwise use.
                      accent: appearance.accent ?? tg.accent,
                      seed: _peerJid,
                    ),
                    child: messages.when(
                      data: (list) {
                        if (list.isNotEmpty) _ensureInitialScroll();
                        return _MessageList(
                          chatKey: widget.chatJid,
                          messages: list,
                          scroll: _scroll,
                          onRetryDecrypt: () => _loadHistory(),
                          onReact: _toggleReaction,
                          onMenu: _showMessageMenu,
                          onToggleSelected: _toggleSelected,
                          selectionMode: _selectionMode,
                          selectedIds: _selection,
                          readAt: ref
                              .watch(chatLastReadProvider(widget.chatJid))
                              .value,
                          unreadCount: _unreadCountHere ?? 0,
                          unreadDividerKey: _unreadDividerKey,
                          focusMessageAnchor: _activeFocusAnchor,
                          focusMessageKey: _focusMessageKey,
                          bubbleStyle: appearance.bubble,
                          isGroup: ui.isGroup,
                        );
                      },
                      loading: () =>
                          const Center(child: CircularProgressIndicator()),
                      error: (e, _) => Center(child: Text('$e')),
                    ),
                  ),
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
                      style: TextStyle(color: tg.accent, fontSize: 13),
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
              if (_selectionMode)
                SelectionBar(
                  count: _selection.length,
                  onForward: _forwardSelection,
                  onDelete: _deleteSelection,
                  onCancel: () => setState(_selection.clear),
                )
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
                _InputBar(
                  controller: _input,
                  focusNode: _focus,
                  onChanged: _vm.onInputChanged,
                  onSend: _send,
                  onAttach: _attachFile,
                  attachEnabled: attachEnabled,
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
                  onDismissed: () => setState(() => _reactingToId = null),
                ),
            ],
          ),
          // Two different destinations, so two different affordances. Scrolling to
          // the bottom is "show me what just happened"; jumping to the first unread
          // is "show me what I missed". Collapsing them means the user who scrolled
          // up to find an older message cannot get back to the new ones in one tap.
          floatingActionButton: _atBottom ? null : _scrollButton(tg),
        ),
        // Covers app bar, transcript, FAB, and input while the OS picker is up
        // so nothing behind it can be tapped or scrolled.
        if (ui.pickingFile)
          const ModalBarrier(dismissible: false, color: Color(0x66000000)),
      ],
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

/// Message list with day separators and an unread marker.
class _MessageList extends StatelessWidget {
  const _MessageList({
    required this.chatKey,
    required this.messages,
    required this.scroll,
    required this.onRetryDecrypt,
    required this.onReact,
    required this.onMenu,
    required this.onToggleSelected,
    required this.selectionMode,
    required this.selectedIds,
    required this.readAt,
    required this.unreadCount,
    required this.unreadDividerKey,
    required this.focusMessageAnchor,
    required this.focusMessageKey,
    required this.bubbleStyle,
    required this.isGroup,
  });

  final String chatKey;
  final List<Message> messages;
  final ScrollController scroll;
  final VoidCallback onRetryDecrypt;

  /// Toggling one emoji on one message. Takes the addressable id, because that
  /// is what a reaction refers to.
  final void Function(String targetId, String emoji) onReact;

  /// Long-press on one message. Gets the row so the page can read the stored
  /// track, which decides both the plaintext notice and whether editing is
  /// offered.
  final void Function(Message message, String body) onMenu;

  /// Toggling a message in the selection.
  final void Function(Message message) onToggleSelected;

  /// Whether the chat is in selection mode, so a tap selects rather than acts.
  final bool selectionMode;

  /// The stanza ids currently selected, in the order they were picked.
  final List<String> selectedIds;

  /// When the user last read this conversation, which is where the unread
  /// boundary goes.
  final DateTime? readAt;

  /// Badge count; used when the read marker alone cannot place a divider.
  final int unreadCount;

  /// Key the unread divider is built with, so the page can scroll to it.
  final GlobalKey unreadDividerKey;

  /// Search / deep-link target; when set, that row gets [focusMessageKey].
  final String? focusMessageAnchor;

  final GlobalKey focusMessageKey;

  /// Corner shape of the bubbles, from this conversation's appearance.
  final BubbleStyle bubbleStyle;

  /// MODE_MULTI: show occupant nicks above incoming bubbles.
  final bool isGroup;

  @override
  Widget build(BuildContext context) {
    if (messages.isEmpty) {
      return Center(child: Text(context.l10n.noMessagesYet));
    }

    final rows = <Widget>[];
    DateTime? lastDay;
    // The first message the user had not read when they last read this chat.
    // Null when everything here has been read, or when the marker is newer than
    // everything we hold (a chat read on another device) — in which case no
    // divider is drawn at all, because a divider with nothing above it is a
    // line across the top of an empty conversation.
    final firstUnread = firstUnreadId(
      messages,
      readAt,
      unreadCount: unreadCount,
    );
    bool unreadMarked = firstUnread == null;

    for (final m in messages) {
      final day = DateTime(
        m.timestamp.year,
        m.timestamp.month,
        m.timestamp.day,
      );
      if (lastDay == null || day != lastDay) {
        rows.add(DateSeparator(date: m.timestamp));
        lastDay = day;
      }
      // Drawn before the message, so it separates "read" from "not read" rather
      // than sitting under the last read one. The comparison is on the row's
      // own id rather than on a flag, because a MAM import can insert messages
      // in the middle and a one-shot flag would end up in the wrong place.
      if (!unreadMarked && matchesUnreadAnchor(m, firstUnread)) {
        rows.add(UnreadDivider(key: unreadDividerKey));
        unreadMarked = true;
      }
      if (EncModeToken.parse(m.encMode) == EncModeToken.error) {
        Widget errorRow = ListTile(
          dense: true,
          leading: Icon(Icons.lock_outline, size: 18, color: context.tg.danger),
          title: Text(
            context.l10n.unableToDecrypt,
            style: TextStyle(
              fontStyle: FontStyle.italic,
              color: context.tg.textSecondary,
            ),
          ),
          trailing: TextButton(
            onPressed: onRetryDecrypt,
            child: Text(context.l10n.retry),
          ),
        );
        if (matchesUnreadAnchor(m, focusMessageAnchor)) {
          errorRow = KeyedSubtree(key: focusMessageKey, child: errorRow);
        }
        rows.add(errorRow);
        continue;
      }
      Widget bubble = _ReactionBubble(
        chatKey: chatKey,
        message: m,
        selectionMode: selectionMode,
        selected: selectedIds.contains(m.stanzaId),
        bubbleStyle: bubbleStyle,
        isGroup: isGroup,
        onReact: (emoji) => onReact(m.stanzaId, emoji),
        onMenu: (body) => onMenu(m, body),
        onToggleSelected: () => onToggleSelected(m),
      );
      if (matchesUnreadAnchor(m, focusMessageAnchor)) {
        bubble = KeyedSubtree(key: focusMessageKey, child: bubble);
      }
      rows.add(bubble);
    }

    return ListView(
      controller: scroll,
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: rows,
    );
  }
}

/// Bottom input bar: attach button, text field, and a button that becomes
/// a microphone whenever the field is empty (docs/05 §4.2).
class _InputBar extends StatelessWidget {
  const _InputBar({
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.onSend,
    required this.onAttach,
    required this.attachEnabled,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final VoidCallback onSend;
  final VoidCallback onAttach;

  /// False when the server has no XEP-0363 — button stays light and inert.
  final bool attachEnabled;

  @override
  Widget build(BuildContext context) {
    final tg = context.tg;
    final l10n = context.l10n;
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        final empty = value.text.trim().isEmpty;
        return Container(
          decoration: BoxDecoration(
            color: tg.pageBackground,
            border: Border(top: BorderSide(color: tg.separator)),
          ),
          padding: const EdgeInsets.fromLTRB(4, 6, 4, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              IconButton(
                icon: const Icon(Icons.attach_file),
                // Supported → primary (darker); unsupported → muted, no press.
                color: attachEnabled ? tg.textPrimary : tg.textSecondary,
                disabledColor: tg.textSecondary,
                tooltip: attachEnabled
                    ? l10n.attachFile
                    : l10n.httpUploadUnavailable,
                onPressed: attachEnabled ? onAttach : null,
              ),
              Expanded(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 120),
                  child: TextField(
                    controller: controller,
                    focusNode: focusNode,
                    minLines: 1,
                    maxLines: 5,
                    textInputAction: TextInputAction.newline,
                    onChanged: onChanged,
                    style: TextStyle(
                      fontSize: TgDimens.messageFontSize,
                      color: tg.textPrimary,
                    ),
                    decoration: InputDecoration(
                      isDense: true,
                      filled: true,
                      fillColor: tg.pageBackground,
                      hintText: l10n.messageComposerHint,
                      hintStyle: TextStyle(color: tg.textSecondary),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(18),
                        borderSide: BorderSide(color: tg.separator),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(18),
                        borderSide: BorderSide(color: tg.separator),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(18),
                        borderSide: BorderSide(color: tg.accent),
                      ),
                    ),
                  ),
                ),
              ),
              IconButton(
                icon: Icon(empty ? Icons.mic_none : Icons.send),
                color: tg.accent,
                onPressed: empty ? () {} : onSend,
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Warns when the contact is not a mutual subscription.
///
/// Without this, a server that refuses stanzas outside a mutual
/// subscription looks exactly like silent data loss: messages vanish and
/// nothing in the interface explains why.
class _SubscriptionBanner extends ConsumerWidget {
  const _SubscriptionBanner({required this.chatJid});

  final String chatJid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tg = context.tg;
    final state = ref.watch(contactStateProvider(chatJid)).value;
    // Nothing to say before the roster has loaded, or when all is well.
    if (state == null || state.isMutual) return const SizedBox.shrink();

    final text = switch (state.subscription) {
      'none' => 'Not a contact yet — the server may refuse messages.',
      'to' =>
        state.asked
            ? 'They can see you. Waiting for them to accept.'
            : 'They can see you, but you cannot see them.',
      'from' =>
        state.asked
            ? 'You can see them. Waiting for them to accept your request.'
            : 'You can see them, but they cannot see you.',
      _ => 'Subscription state: ${state.subscription}',
    };

    return Material(
      color: tg.danger.withValues(alpha: 0.12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          children: [
            Icon(Icons.info_outline, size: 18, color: tg.danger),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: TextStyle(fontSize: 13, color: tg.textPrimary),
              ),
            ),
            if (state.subscription != 'both')
              TextButton(
                onPressed: () {
                  final r = resolveChatKey(chatJid);
                  r.session.xmpp.requestSubscription(JID.fromString(r.jid));
                },
                child: Text(context.l10n.askAgain),
              ),
          ],
        ),
      ),
    );
  }
}

/// A bubble plus whatever reactions its message carries.
///
/// Split out so the chips can come from their own provider: they change
/// whenever anyone reacts, which is independent of the message list rebuilding.
class _ReactionBubble extends ConsumerWidget {
  const _ReactionBubble({
    required this.chatKey,
    required this.message,
    required this.selectionMode,
    required this.selected,
    required this.bubbleStyle,
    required this.isGroup,
    required this.onReact,
    required this.onMenu,
    required this.onToggleSelected,
  });

  final String chatKey;
  final Message message;
  final bool selectionMode;
  final bool selected;
  final BubbleStyle bubbleStyle;
  final bool isGroup;
  final void Function(String emoji) onReact;
  final void Function(String body) onMenu;
  final void Function() onToggleSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Keyed on the stored id, which is the origin-id when the sender published
    // one. Empty means the message cannot be addressed, so it is drawn without
    // chips rather than with chips nobody could add to.
    final targetId = message.stanzaId;
    final reactions = targetId.isEmpty
        ? const <ReactionGroup>[]
        : ref
                  .watch(
                    reactionGroupsProvider((
                      chatKey: chatKey,
                      targetId: targetId,
                    )),
                  )
                  .value ??
              const [];
    final nick = isGroup && message.incoming
        ? _occupantNick(message.sender)
        : null;
    return MessageBubble(
      text: message.body,
      time: message.timestamp,
      side: message.incoming ? BubbleSide.incoming : BubbleSide.outgoing,
      senderName: nick,
      senderColor: nick == null ? null : _nickColor(nick),
      delivered: message.delivered,
      displayed: message.displayed,
      failed: message.deliveryError.isNotEmpty,
      // What the message actually used, from what the sender declared — not
      // what we would have chosen. Read back from the row rather than
      // recomputed, so the label survives a change of mind afterwards.
      track: EncModeToken.parse(message.encMode).track ?? Track.none,
      reactions: reactions,
      retracted: message.retracted,
      edited: message.editedAt != null,
      mine: !message.incoming,
      selected: selected,
      selectionMode: selectionMode,
      bubbleStyle: bubbleStyle,
      message: message,
      chatKey: chatKey,
      onReact: onReact,
      // A long press still opens the context menu when nothing is selected;
      // once a selection exists, long press adds to it, which is what a user
      // picking five messages is actually doing.
      onLongPress: message.retracted
          ? null
          : selectionMode
          ? onToggleSelected
          : () => onMenu(message.body),
      onTap: selectionMode ? onToggleSelected : null,
    );
  }
}

/// Occupant nick from a stored sender (`room@server/nick` or bare nick).
String? _occupantNick(String sender) {
  if (sender.isEmpty || sender == 'me') return null;
  final slash = sender.indexOf('/');
  if (slash >= 0 && slash + 1 < sender.length) {
    return sender.substring(slash + 1);
  }
  return sender;
}

/// Stable tint for a nick in group transcripts (docs/05).
Color _nickColor(String nick) {
  final hue = (nick.hashCode & 0x7fffffff) % 360;
  return HSLColor.fromAHSL(1, hue.toDouble(), 0.55, 0.42).toColor();
}
