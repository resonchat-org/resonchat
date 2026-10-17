// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The long-press menu on a message (Telegram's `ChatActivity` context menu).
//
// What is on offer depends on who wrote the message, and getting that wrong is
// not a cosmetic problem. Offering "delete for everyone" on somebody else's
// message implies we could — and we cannot: the retraction is an instruction
// to the recipient's own client, so it only ever affects copies of *our*
// messages. Offering "edit" on somebody else's message is the same mistake.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../crypto/omemo/track.dart';
import '../theme.dart';

/// The actions available on one message.
class MessageActions {
  const MessageActions({
    required this.canReply,
    required this.canForward,
    required this.canReact,
    required this.canCopy,
    required this.canTranslate,
    required this.canSelect,
    required this.canEdit,
    required this.canRetract,
    required this.canSaveFile,
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

  /// External HTTP translation for translatable plaintext (not files / emoji).
  final bool canTranslate;

  /// Enter multi-select with this message as the first pick (addressable only).
  final bool canSelect;

  /// Only our own messages: an edit replaces content, and we cannot replace
  /// somebody else's.
  final bool canEdit;

  /// Only our own, and only while it is addressable. A message with no
  /// origin-id cannot be referenced, so offering the action would mean
  /// retracting "the last message" instead.
  final bool canRetract;

  /// File / image message with a downloaded private cache copy (Copinc
  /// “Save file”). Hidden for plain text and for undownloaded attachments.
  final bool canSaveFile;

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
    bool canTranslate = false,
  }) {
    return MessageActions(
      canReply: !retracted && addressable,
      canForward: !retracted && decrypted,
      canReact: !retracted,
      canCopy: decrypted && !retracted,
      canTranslate: canTranslate,
      canSelect: !retracted && addressable,
      canEdit: mine && !retracted && decrypted,
      canRetract: mine && !retracted && addressable,
      canSaveFile: !retracted && canSaveFile,
      isPinned: pinned,
    );
  }

  bool get isEmpty =>
      !canReply &&
      !canReact &&
      !canCopy &&
      !canTranslate &&
      !canSelect &&
      !canEdit &&
      !canForward &&
      !canRetract &&
      !canSaveFile;
}

/// The result of the menu.
enum MessageAction {
  reply,
  react,
  copy,
  translate,
  select,
  edit,
  forward,
  pin,
  retract,
  saveFile,
}

/// Shows the menu and returns what the user picked, or null.
Future<MessageAction?> showMessageMenu(
  BuildContext context, {
  required MessageActions actions,
  required bool trackIsPlaintext,
}) {
  final l10n = context.l10n;
  return showModalBottomSheet<MessageAction>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      // Scrollable, and shrink-wrapped so a short menu still hugs its content.
      //
      // A Column here does not scroll, it overflows: the menu offers up to ten
      // rows and a modal sheet is capped at 9/16 of the screen, which on a
      // normal phone is under the height of a message that can be replied to,
      // reacted to, copied, translated, selected, forwarded, saved, edited,
      // pinned and retracted. The rows that fell off the bottom — "delete for
      // everyone" among them — were drawn outside the sheet and could not be
      // tapped at all.
      child: ListView(
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        children: [
          if (actions.canReply)
            ListTile(
              leading: const Icon(Icons.reply),
              title: Text(l10n.reply),
              onTap: () => Navigator.of(context).pop(MessageAction.reply),
            ),
          if (actions.canReact)
            ListTile(
              leading: const Icon(Icons.add_reaction_outlined),
              title: Text(l10n.react),
              onTap: () => Navigator.of(context).pop(MessageAction.react),
            ),
          if (actions.canCopy)
            ListTile(
              leading: const Icon(Icons.copy),
              title: Text(l10n.copyText),
              onTap: () => Navigator.of(context).pop(MessageAction.copy),
            ),
          if (actions.canTranslate)
            ListTile(
              leading: const Icon(Icons.translate),
              title: Text(l10n.translate),
              onTap: () => Navigator.of(context).pop(MessageAction.translate),
            ),
          if (actions.canSelect)
            ListTile(
              leading: const Icon(Icons.checklist),
              title: Text(l10n.selectMessages),
              onTap: () => Navigator.of(context).pop(MessageAction.select),
            ),
          if (actions.canForward)
            ListTile(
              leading: const Icon(Icons.forward),
              title: Text(l10n.forward),
              onTap: () => Navigator.of(context).pop(MessageAction.forward),
            ),
          if (actions.canSaveFile)
            ListTile(
              leading: const Icon(Icons.save_alt),
              title: Text(l10n.saveFile),
              onTap: () => Navigator.of(context).pop(MessageAction.saveFile),
            ),
          if (actions.canEdit)
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: Text(l10n.edit),
              onTap: () => Navigator.of(context).pop(MessageAction.edit),
            ),
          if (actions.canEdit)
            ListTile(
              leading: const Icon(Icons.push_pin_outlined),
              title: Text(actions.isPinned ? l10n.unpin : l10n.pin),
              onTap: () => Navigator.of(context).pop(MessageAction.pin),
            ),
          if (actions.canRetract)
            ListTile(
              leading: Icon(
                Icons.delete_outline,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text(
                l10n.deleteForEveryone,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              onTap: () => Navigator.of(context).pop(MessageAction.retract),
            ),
          // Says so plainly rather than hiding the option: a message on NO is
          // readable by anyone with server access, and a user who assumes
          // "delete" reaches those copies is wrong about something that cannot
          // be fixed afterwards.
          if (actions.canRetract && trackIsPlaintext)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Text(
                l10n.deleteUnencryptedWarning,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    ),
  );
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
                // Delete-all only for our own messages, and only where it can
                // actually work: XEP-0424 is per message, so a mixed selection
                // deletes the subset we sent and says so.
                onPressed: count == 0 ? null : onDelete,
                icon: const Icon(Icons.delete_outline),
                tooltip: l10n.deleteMine,
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
