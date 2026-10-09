// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The two dialogs docs/10 §5 requires, and the wording rule they exist for.
//
// Both dialogs tell the user a true consequence and let them decide. Neither
// one blocks them, and neither one decides for them. What they must not do is
// soften the consequence into something that reads as "probably fine", because
// a user who cannot tell that their contact will not be able to read the
// message will simply send it.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../account/resolve.dart';
import '../../l10n/l10n.dart';
import '../../omemo/track.dart';
import '../../omemo/track_advice.dart';
import '../../omemo/track_resolver.dart';
import '../../state/providers.dart';
import '../../xmpp/capabilities.dart';

/// The banner shown when a contact's capabilities changed (docs/10 §8).
///
/// Two shapes, because the two directions are not equally urgent. An upgrade
/// is a quiet offer the user can decline forever. A downgrade that breaks the
/// chosen track is stated plainly, because the alternative to reading it is a
/// message that silently fails to send.
class TrackAdviceBanner extends StatelessWidget {
  const TrackAdviceBanner({
    super.key,
    required this.advice,
    required this.onSwitch,
    required this.onDismiss,
  });

  final TrackAdvice advice;
  final VoidCallback onSwitch;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final urgent = advice.kind == TrackAdviceKind.chosenTrackBlocked;
    return Material(
      color: urgent
          ? theme.colorScheme.errorContainer
          : theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          children: [
            Icon(
              urgent ? Icons.warning_amber_rounded : Icons.shield,
              size: 18,
              color: urgent
                  ? theme.colorScheme.onErrorContainer
                  : theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                advice.message,
                style: TextStyle(
                  fontSize: 13,
                  color: urgent
                      ? theme.colorScheme.onErrorContainer
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            TextButton(
              onPressed: onSwitch,
              child: Text(l10n.switchToTrack(advice.suggestion.label)),
            ),
            IconButton(
              onPressed: onDismiss,
              icon: const Icon(Icons.close, size: 18),
              tooltip: l10n.dismiss,
              color: urgent
                  ? theme.colorScheme.onErrorContainer
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

/// The track picker: the user's protocol choice for one conversation.
///
/// Every track is offered. That is the decision docs/10 makes: the client
/// does not remove options the user may want, it tells them what each one
/// costs and lets them pick. Hiding "no encryption" behind a disclaimer would
/// be the same paternalism as refusing it outright, and would push anyone who
/// genuinely wants it towards a client that does not ask at all.
///
/// The banner at the top says whether the peer can read the current choice —
/// and it says it without changing the selection. A contact's capabilities
/// changing is information, not a decision.
Future<void> showTrackPicker(
  BuildContext context,
  WidgetRef ref,
  String chatJid,
) async {
  // Everything below reads already-resolved provider values and shows the
  // sheet synchronously.
  //
  // An earlier version awaited a capability lookup first. On a contact with a
  // long-lived device list that is a fetch per stale device — several seconds
  // in which tapping the badge looked like it had done nothing. A picker is
  // about *choosing*; what the peer can read is a separate fact, and the
  // banner updates when it is known.
  final current = ref.read(chatTrackProvider(chatJid)).value;
  final global = ref.read(globalTrackProvider).value;
  final caps = ref.read(chatCapabilitiesProvider(chatJid)).value;

  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => _TrackPicker(
      chatJid: chatJid,
      current: current,
      global: global,
      capabilities: caps,
    ),
  );
}

class _TrackPicker extends ConsumerStatefulWidget {
  const _TrackPicker({
    required this.chatJid,
    required this.current,
    required this.global,
    required this.capabilities,
  });

  final String chatJid;
  final Track? current;
  final Track? global;
  final ChatCapabilities? capabilities;

  @override
  ConsumerState<_TrackPicker> createState() => _TrackPickerState();
}

class _TrackPickerState extends ConsumerState<_TrackPicker> {
  @override
  Widget build(BuildContext context) {
    // Re-read as a Consumer: the values above are snapshots taken when the
    // sheet was opened, and the capability resolver finishes seconds later.
    // Track.standard while the stored value is still loading: the sheet has to
    // render something, and standard is the same default a fresh install gets,
    // so the checkmark cannot be wrong for more than a frame.
    final current =
        ref.watch(chatTrackProvider(widget.chatJid)).value ??
        widget.current ??
        Track.standard;
    final global =
        ref.watch(globalTrackProvider).value ?? widget.global ?? Track.standard;
    final caps =
        ref.watch(chatCapabilitiesProvider(widget.chatJid)).value ??
        widget.capabilities;
    final override = ref.watch(chatTrackOverrideProvider(widget.chatJid)).value;

    final resolution = resolveTrack(requested: current, capabilities: caps);
    final theme = Theme.of(context);
    final l10n = context.l10n;

    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                l10n.encryptionForThisChat,
                style: theme.textTheme.titleMedium,
              ),
            ),
            if (!resolution.canSend)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Text(
                  '${resolution.blocked!.localizedConsequence(l10n)} '
                  '${l10n.messagesOnTrackWillAsk(current.label)}',
                  style: TextStyle(
                    color: theme.colorScheme.error,
                    fontSize: 13,
                  ),
                ),
              ),
            for (final track in Track.values)
              _TrackOption(
                track: track,
                selected: track == current,
                // Marked "default" rather than "selected" when no override
                // exists, so it stays visible that clearing the override is a
                // choice with its own consequences.
                inherited: override == null && track == global,
                onTap: () async {
                  Navigator.of(context).pop();
                  await setChatTrack(ref, widget.chatJid, track);
                },
              ),
            const SizedBox(height: 8),
            if (override != null)
              TextButton(
                onPressed: () async {
                  Navigator.of(context).pop();
                  await setChatTrack(ref, widget.chatJid, null);
                },
                child: Text(l10n.useGlobalDefault(global.label)),
              ),
            const Divider(),
            BlockContactTile(
              contact: resolveChatKey(widget.chatJid).jid,
              blocked: ref.watch(isBlockedProvider(widget.chatJid)),
              onToggle: () async {
                final messenger = ScaffoldMessenger.of(context);
                final wasBlocked = ref.read(isBlockedProvider(widget.chatJid));
                Navigator.of(context).pop();
                await toggleBlocked(
                  ref,
                  widget.chatJid,
                  currentlyBlocked: wasBlocked,
                );
                messenger.showSnackBar(
                  SnackBar(
                    content: Text(
                      wasBlocked ? l10n.unblockedSnack : l10n.blockedSnack,
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

class _TrackOption extends StatelessWidget {
  const _TrackOption({
    required this.track,
    required this.selected,
    required this.inherited,
    required this.onTap,
  });

  final Track track;
  final bool selected;
  final bool inherited;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return ListTile(
      leading: Icon(
        track.icon,
        color: track == Track.none ? theme.colorScheme.error : null,
      ),
      title: Text('${track.label}  ${track.localizedDescription(l10n)}'),
      subtitle: inherited ? Text(l10n.currentlyYourGlobalDefault) : null,
      trailing: selected
          ? Icon(Icons.check, color: theme.colorScheme.primary)
          : null,
      selected: selected,
      onTap: onTap,
    );
  }
}

/// Asks the user what to do when their chosen track cannot be used.
///
/// Returns the track to send on instead, or null to cancel. There is no
/// "send anyway" button here: falling through to another track is the user's
/// call, and pressing cancel leaves the text in the box.
Future<Track?> askTrackSubstitute(
  BuildContext context, {
  required TrackBlocked blocked,
  required Track alternative,
}) {
  final l10n = context.l10n;
  return showDialog<Track>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(blocked.localizedTitle(l10n)),
      content: Text(
        '${blocked.localizedConsequence(l10n)}\n\n'
        '${blocked.localizedOutcome(l10n)}',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(alternative),
          child: Text(l10n.sendWithTrack(alternative.label)),
        ),
      ],
    ),
  );
}

/// Confirms a choice of plaintext, then returns true if the user agreed.
///
/// Called every time plaintext is selected, not once per conversation. The
/// consequence is per message and depends on who is on the other end, and a
/// confirmation the user has already dismissed teaches them that the prompt
/// is not a real question.
Future<bool> confirmPlaintext(
  BuildContext context, {
  required String contact,
  required Track alternative,
}) async {
  final l10n = context.l10n;
  final agreed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(l10n.sendWithoutEncryption),
      content: Text(l10n.sendWithoutEncryptionBody(contact, alternative.label)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l10n.sendInTheClear),
        ),
      ],
    ),
  );
  return agreed ?? false;
}

/// The block/unblock entry in the conversation's menu.
///
/// The wording is the point. "Block" in other apps implies the messages stop
/// arriving, and users believe it: they block someone and then trust that
/// there is nothing left to read. The server still routes them — what blocking
/// does is stop *us* from opening them — so this says exactly that, in the
/// place where the decision is made.
class BlockContactTile extends StatelessWidget {
  const BlockContactTile({
    super.key,
    required this.contact,
    required this.blocked,
    required this.onToggle,
  });

  final String contact;
  final bool blocked;
  final Future<void> Function() onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return ListTile(
      leading: Icon(
        blocked ? Icons.lock_open : Icons.block,
        color: blocked ? theme.colorScheme.primary : theme.colorScheme.error,
      ),
      title: Text(
        blocked ? l10n.unblockContact(contact) : l10n.blockContact(contact),
      ),
      subtitle: Text(
        blocked ? l10n.unblockContactSubtitle : l10n.blockContactSubtitle,
        style: TextStyle(
          fontSize: 12,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      onTap: onToggle,
    );
  }
}
