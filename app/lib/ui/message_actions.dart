// Copyright (C) 2026 resonchat contributors.
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

import '../omemo/track.dart';

/// The actions available on one message.
class MessageActions {
  const MessageActions({
    required this.canReact,
    required this.canCopy,
    required this.canEdit,
    required this.canRetract,
  });

  /// Reactions work on anything we can see, including a message we could not
  /// decrypt — that is exactly when the sender most wants to hear that we read
  /// it.
  final bool canReact;

  final bool canCopy;

  /// Only our own messages: an edit replaces content, and we cannot replace
  /// somebody else's.
  final bool canEdit;

  /// Only our own, and only while it is addressable. A message with no
  /// origin-id cannot be referenced, so offering the action would mean
  /// retracting "the last message" instead.
  final bool canRetract;

  factory MessageActions.for_({
    required bool mine,
    required bool retracted,
    required bool decrypted,
    required bool addressable,
  }) {
    return MessageActions(
      canReact: !retracted,
      canCopy: decrypted && !retracted,
      canEdit: mine && !retracted && decrypted,
      canRetract: mine && !retracted && addressable,
    );
  }

  bool get isEmpty =>
      !canReact && !canCopy && !canEdit && !canRetract;
}

/// The result of the menu.
enum MessageAction { react, copy, edit, retract }

/// Shows the menu and returns what the user picked, or null.
Future<MessageAction?> showMessageMenu(
  BuildContext context, {
  required MessageActions actions,
  required bool trackIsPlaintext,
}) {
  return showModalBottomSheet<MessageAction>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (actions.canReact)
            ListTile(
              leading: const Icon(Icons.add_reaction_outlined),
              title: const Text('React'),
              onTap: () => Navigator.of(context).pop(MessageAction.react),
            ),
          if (actions.canCopy)
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('Copy text'),
              onTap: () => Navigator.of(context).pop(MessageAction.copy),
            ),
          if (actions.canEdit)
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Edit'),
              onTap: () => Navigator.of(context).pop(MessageAction.edit),
            ),
          if (actions.canRetract)
            ListTile(
              leading: Icon(
                Icons.delete_outline,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text(
                'Delete for everyone',
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
                'This message went out unencrypted. Deleting it here removes '
                'your copy, but anyone who already read it still has it.',
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
                  tooltip: 'React',
                ),
              IconButton(
                onPressed: onDismissed,
                icon: const Icon(Icons.close),
                tooltip: 'Cancel',
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
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: 'Edit message',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _submit(),
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                onPressed: _busy ? null : widget.onCancel,
                icon: const Icon(Icons.close),
                tooltip: 'Cancel',
              ),
              IconButton(
                onPressed: _busy ? null : _submit,
                icon: const Icon(Icons.check),
                tooltip: 'Save',
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
                'Messages in this chat are not encrypted.',
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