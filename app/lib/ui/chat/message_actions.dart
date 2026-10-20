// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The long-press menu on a message: a grid beside the bubble, not a sheet.
//
// Retract is offered on our own messages (XEP-0424) and, in a group, on
// other people's messages when we are a moderator and the room supports
// XEP-0425. Edit stays limited to our own messages.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'package:resonchat/crypto/dual/track.dart';
import 'package:resonchat/l10n/l10n.dart';
import 'package:resonchat/ui/theme.dart';

/// The actions available on one message.
class MessageActions {
  const MessageActions({
    required this.canReply,
    required this.canForward,
    required this.canReact,
    required this.canCopy,
    required this.canCopySelection,
    required this.canTranslate,
    required this.canSelect,
    required this.canEdit,
    required this.canRetract,
    required this.canSaveFile,
    this.canSaveSticker = false,
    required this.isPinned,
  });

  /// Replies address a message by its origin-id, so they need an addressable
  /// one. A message from a client that published no stable id cannot be
  /// replied to by reference — offering it would produce a reply whose
  /// `> ` quote is the only link to its target.
  final bool canReply;

  /// Forwarding works on anything readable, including an undecryptable
  /// message — but forwarding a placeholder would send the reader a sentence
  /// about the app rather than the message.
  final bool canForward;

  /// Reactions work on anything we can see, including a message we could not
  /// decrypt — that is exactly when the sender most wants to hear that we read
  /// it.
  final bool canReact;

  final bool canCopy;

  /// Copy only the range the user has selected in a text message.
  ///
  /// Separate from [canCopy], which copies the whole body. Images and other
  /// files do not offer it.
  final bool canCopySelection;

  /// External HTTP translation for translatable plaintext (not files / emoji).
  final bool canTranslate;

  /// Enter multi-select with this message as the first pick (addressable only).
  final bool canSelect;

  /// Only our own messages: an edit replaces content, and we cannot replace
  /// somebody else's.
  final bool canEdit;

  /// Our own messages (XEP-0424), or someone else's in a group we moderate
  /// (XEP-0425). The message still has to be addressable.
  final bool canRetract;

  /// File / image message with a downloaded private cache copy (Copinc
  /// “Save file”). Hidden for plain text and for undownloaded attachments.
  final bool canSaveFile;

  /// Save this image into the account sticker collection.
  ///
  /// Only an image that is already on disk. Other files, and images that
  /// have not been downloaded, do not offer it.
  final bool canSaveSticker;

  /// Whether this message is already pinned, so the entry can offer the
  /// opposite action rather than a verb that does the wrong thing.
  final bool isPinned;

  factory MessageActions.for_({
    required bool mine,
    required bool retracted,
    required bool decrypted,
    required bool addressable,
    required bool pinned,
    bool canSaveFile = false,
    bool canSaveSticker = false,
    bool canTranslate = false,
    bool canCopySelection = false,
    bool moderate = false,
    bool groupchat = false,
    bool hasRoomStanzaId = true,
  }) {
    return MessageActions(
      canReply: !retracted && addressable,
      canForward: !retracted && decrypted,
      canReact: !retracted,
      canCopy: decrypted && !retracted,
      canCopySelection: decrypted && !retracted && canCopySelection,
      canTranslate: canTranslate,
      canSelect: !retracted && addressable,
      canEdit: mine && !retracted && decrypted,
      // Group messages are addressed by the room stanza-id. Offering retract
      // without that id sends the origin-id, which other clients cannot match.
      canRetract:
          !retracted &&
          addressable &&
          (moderate || (mine && (!groupchat || hasRoomStanzaId))),
      canSaveFile: !retracted && canSaveFile,
      canSaveSticker: !retracted && canSaveSticker,
      isPinned: pinned,
    );
  }

  bool get isEmpty =>
      !canReply &&
      !canReact &&
      !canCopy &&
      !canCopySelection &&
      !canTranslate &&
      !canSelect &&
      !canEdit &&
      !canForward &&
      !canRetract &&
      !canSaveFile &&
      !canSaveSticker;
}

/// The result of the menu.
enum MessageAction {
  reply,
  react,
  copy,
  copySelection,
  translate,
  select,
  edit,
  forward,
  pin,
  retract,
  saveFile,
  saveSticker,
}

/// One cell in the grid beside a long-pressed message.
class _MenuItem {
  const _MenuItem({
    required this.icon,
    required this.label,
    required this.action,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final MessageAction action;
  final bool danger;
}

/// Shows the menu beside [anchor] and returns what the user picked, or null.
///
/// [anchor] is the bubble in global coordinates. Taps outside the bubble and
/// the menu dismiss it; taps on the bubble pass through so a text selection
/// can be adjusted.
Future<MessageAction?> showMessageMenu(
  BuildContext context, {
  required MessageActions actions,
  required bool trackIsPlaintext,
  required Rect anchor,
}) {
  final overlay = Overlay.of(context);
  final overlayBox = overlay.context.findRenderObject() as RenderBox?;
  final localAnchor = overlayBox == null
      ? anchor
      : Rect.fromPoints(
          overlayBox.globalToLocal(anchor.topLeft),
          overlayBox.globalToLocal(anchor.bottomRight),
        );
  final completer = Completer<MessageAction?>();
  late OverlayEntry entry;
  void finish(MessageAction? action) {
    if (completer.isCompleted) return;
    entry.remove();
    completer.complete(action);
  }

  entry = OverlayEntry(
    builder: (context) => _AnchoredMessageMenu(
      anchor: localAnchor,
      actions: actions,
      trackIsPlaintext: trackIsPlaintext,
      onPick: finish,
    ),
  );
  overlay.insert(entry);
  return completer.future;
}

class _AnchoredMessageMenu extends StatelessWidget {
  const _AnchoredMessageMenu({
    required this.anchor,
    required this.actions,
    required this.trackIsPlaintext,
    required this.onPick,
  });

  final Rect anchor;
  final MessageActions actions;
  final bool trackIsPlaintext;
  final void Function(MessageAction? action) onPick;

  static const double _cellW = 76;
  static const double _cellH = 64;

  List<_MenuItem> _items(AppLocalizations l10n) {
    return [
      if (actions.canReply)
        _MenuItem(
          icon: Icons.reply,
          label: l10n.reply,
          action: MessageAction.reply,
        ),
      if (actions.canReact)
        _MenuItem(
          icon: Icons.add_reaction_outlined,
          label: l10n.react,
          action: MessageAction.react,
        ),
      if (actions.canCopy)
        _MenuItem(
          icon: Icons.copy,
          label: l10n.copyText,
          action: MessageAction.copy,
        ),
      if (actions.canCopySelection)
        _MenuItem(
          icon: Icons.highlight_alt,
          label: l10n.copySelection,
          action: MessageAction.copySelection,
        ),
      if (actions.canTranslate)
        _MenuItem(
          icon: Icons.translate,
          label: l10n.translate,
          action: MessageAction.translate,
        ),
      if (actions.canSelect)
        _MenuItem(
          icon: Icons.checklist,
          label: l10n.selectMessages,
          action: MessageAction.select,
        ),
      if (actions.canForward)
        _MenuItem(
          icon: Icons.forward,
          label: l10n.forward,
          action: MessageAction.forward,
        ),
      if (actions.canSaveFile)
        _MenuItem(
          icon: Icons.save_alt,
          label: l10n.saveFile,
          action: MessageAction.saveFile,
        ),
      if (actions.canSaveSticker)
        _MenuItem(
          icon: Icons.emoji_emotions_outlined,
          label: l10n.saveSticker,
          action: MessageAction.saveSticker,
        ),
      if (actions.canEdit)
        _MenuItem(
          icon: Icons.edit_outlined,
          label: l10n.edit,
          action: MessageAction.edit,
        ),
      if (actions.canEdit)
        _MenuItem(
          icon: Icons.push_pin_outlined,
          label: actions.isPinned ? l10n.unpin : l10n.pin,
          action: MessageAction.pin,
        ),
      if (actions.canRetract)
        _MenuItem(
          icon: Icons.undo,
          label: l10n.retractMessage,
          action: MessageAction.retract,
          danger: true,
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final items = _items(l10n);
    final cols = math.min(4, math.max(1, items.length));
    final rows = (items.length / cols).ceil();
    final menuW = cols * _cellW;
    final warn = actions.canRetract && trackIsPlaintext;
    final menuH = rows * _cellH + (warn ? 44 : 0) + 8;
    final size = MediaQuery.sizeOf(context);
    final pad = MediaQuery.paddingOf(context);
    var top = anchor.top - menuH - 8;
    if (top < pad.top + 8) top = anchor.bottom + 8;
    if (top + menuH > size.height - pad.bottom - 8) {
      top = math.max(pad.top + 8, size.height - pad.bottom - menuH - 8);
    }
    var left = anchor.center.dx - menuW / 2;
    left = left.clamp(8.0, math.max(8.0, size.width - menuW - 8));
    final theme = Theme.of(context);
    return Stack(
      children: [
        Positioned.fill(
          child: _MenuBarrier(
            hole: anchor.inflate(28),
            onDismiss: () => onPick(null),
          ),
        ),
        Positioned(
          left: left,
          top: top,
          width: menuW,
          child: Material(
            elevation: 8,
            color: theme.colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                GridView.count(
                  crossAxisCount: cols,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  childAspectRatio: _cellW / _cellH,
                  children: [
                    for (final item in items)
                      InkWell(
                        onTap: () => onPick(item.action),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 8,
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                item.icon,
                                size: 22,
                                color: item.danger
                                    ? theme.colorScheme.error
                                    : theme.colorScheme.onSurface,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                item.label,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 11,
                                  height: 1.1,
                                  color: item.danger
                                      ? theme.colorScheme.error
                                      : theme.colorScheme.onSurface,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
                if (warn)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                    child: Text(
                      l10n.retractUnencryptedWarning,
                      style: TextStyle(
                        fontSize: 11,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Full-screen tap target with a hole over the bubble.
class _MenuBarrier extends LeafRenderObjectWidget {
  const _MenuBarrier({required this.hole, required this.onDismiss});

  final Rect hole;
  final VoidCallback onDismiss;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _MenuBarrierBox(hole: hole, onDismiss: onDismiss);
  }

  @override
  void updateRenderObject(BuildContext context, _MenuBarrierBox renderObject) {
    renderObject
      ..hole = hole
      ..onDismiss = onDismiss;
  }
}

class _MenuBarrierBox extends RenderBox {
  _MenuBarrierBox({required this._hole, required this._onDismiss});

  Rect _hole;
  VoidCallback _onDismiss;

  set hole(Rect value) {
    if (_hole == value) return;
    _hole = value;
    markNeedsPaint();
  }

  set onDismiss(VoidCallback value) => _onDismiss = value;

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (_hole.contains(position)) return false;
    result.add(BoxHitTestEntry(this, position));
    return true;
  }

  @override
  void handleEvent(PointerEvent event, BoxHitTestEntry entry) {
    if (event is PointerDownEvent) _onDismiss();
  }

  @override
  void paint(PaintingContext context, Offset offset) {}
}

/// The action bar shown while messages are selected.
///
/// Replaces the input bar rather than sitting above it, for the same reason the
/// edit composer does: two things that both accept input in one chat is
/// ambiguous about where a keystroke goes.
class SelectionBar extends StatelessWidget {
  const SelectionBar({
    super.key,
    required this.count,
    required this.onForward,
    required this.onDelete,
    required this.onCancel,
  });

  final int count;
  final VoidCallback onForward;
  final VoidCallback onDelete;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
          child: Row(
            children: [
              IconButton(
                onPressed: onCancel,
                icon: const Icon(Icons.close),
                tooltip: l10n.cancel,
              ),
              Expanded(
                child: Text(
                  count == 0 ? l10n.selectMessages : l10n.selectedCount(count),
                  style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
              IconButton(
                onPressed: count == 0 ? null : onForward,
                icon: const Icon(Icons.forward),
                tooltip: l10n.forward,
              ),
              IconButton(
                // Retract only our own messages, and only where it can
                // actually work: XEP-0424 is per message, so a mixed selection
                // retracts the subset we sent and says so.
                onPressed: count == 0 ? null : onDelete,
                icon: const Icon(Icons.undo),
                tooltip: l10n.retractMine,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The quick reaction strip shown after "React".
///
/// A strip rather than a full picker: the common reactions are the ones people
/// reach for, and a grid of several hundred emoji is a worse answer to "react
/// to this" than six buttons.
class QuickReactionBar extends StatelessWidget {
  const QuickReactionBar({
    super.key,
    required this.emoji,
    required this.onPicked,
    required this.onDismissed,
  });

  final List<String> emoji;
  final void Function(String emoji) onPicked;
  final VoidCallback onDismissed;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              for (final e in emoji)
                IconButton(
                  onPressed: () => onPicked(e),
                  icon: Text(e, style: const TextStyle(fontSize: 24)),
                  tooltip: l10n.react,
                ),
              IconButton(
                onPressed: onDismissed,
                icon: const Icon(Icons.close),
                tooltip: l10n.cancel,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The strip above the input bar while a reply is being written.
///
/// Above the input rather than in it: the text being typed is the reply, and
/// mixing a quote into the same field means the user edits their own reply by
/// accident.
class ReplyPreview extends StatelessWidget {
  const ReplyPreview({
    super.key,
    required this.author,
    required this.body,
    required this.onCancel,
  });

  final String author;
  final String body;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 3,
                constraints: const BoxConstraints(minHeight: 20),
                margin: const EdgeInsets.only(top: 2, right: 10),
                color: theme.colorScheme.primary,
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.replyingTo(author),
                      style: TextStyle(
                        fontSize: TgDimens.timeFontSize,
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    Text(
                      body,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: TgDimens.timeFontSize,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: onCancel,
                icon: const Icon(Icons.close, size: 18),
                tooltip: l10n.cancelReply,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shown instead of the message while it is being corrected.
class EditComposer extends StatefulWidget {
  const EditComposer({
    super.key,
    required this.initialText,
    required this.onSubmit,
    required this.onCancel,
  });

  final String initialText;
  final Future<void> Function(String body) onSubmit;
  final VoidCallback onCancel;

  @override
  State<EditComposer> createState() => _EditComposerState();
}

class _EditComposerState extends State<EditComposer> {
  late final _controller = TextEditingController(text: widget.initialText);
  final _focus = FocusNode();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Select-all, so the common case — fixing a typo — is a straight
    // overwrite rather than a dance with the cursor.
    _controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: widget.initialText.length,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      await widget.onSubmit(text);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  focusNode: _focus,
                  minLines: 1,
                  maxLines: 6,
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: l10n.editMessageHint,
                    border: const OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _submit(),
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                onPressed: _busy ? null : widget.onCancel,
                icon: const Icon(Icons.close),
                tooltip: l10n.cancel,
              ),
              IconButton(
                onPressed: _busy ? null : _submit,
                icon: const Icon(Icons.check),
                tooltip: l10n.save,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The plain-text notice shown above an unencrypted conversation.
///
/// Persistent rather than a one-time banner, because the condition does not
/// change while the user reads it: a message sent now is readable by whoever
/// stores it, and no later event makes that untrue.
class PlaintextNotice extends StatelessWidget {
  const PlaintextNotice({super.key, required this.visible});

  final bool visible;

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(
          children: [
            Icon(
              Icons.lock_open,
              size: 14,
              color: theme.colorScheme.onErrorContainer,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                context.l10n.messagesNotEncrypted,
                style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.onErrorContainer,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The track of a stored message, for callers that only need the enum.
Track storedTrack(String encMode) =>
    EncModeToken.parse(encMode).track ?? Track.none;
