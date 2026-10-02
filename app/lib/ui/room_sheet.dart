// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Group chats: joining a room, and the member list.
//
// Both live in one sheet because they are one decision: a room is identified by
// `room@server` plus the nickname you want inside it, and the nickname is a
// property of the join, not of the room. Somebody who is "alice" on Monday and
// "alice2" on Tuesday is two different occupants of the same room.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:moxxmpp/moxxmpp.dart';

import '../state/providers.dart';
import '../xmpp/muc.dart';
import 'theme.dart';

/// Asks for a room JID and a nickname, then joins.
class JoinRoomSheet extends ConsumerStatefulWidget {
  const JoinRoomSheet({super.key});

  @override
  ConsumerState<JoinRoomSheet> createState() => _JoinRoomSheetState();
}

class _JoinRoomSheetState extends ConsumerState<JoinRoomSheet> {
  final _room = TextEditingController();
  final _nick = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Default the nickname to our own local part: it is what everyone else
    // will see, and an empty one is rejected by the server.
    _nick.text = ref.read(xmppServiceProvider).myJid?.split('@').first ?? '';
  }

  @override
  void dispose() {
    _room.dispose();
    _nick.dispose();
    super.dispose();
  }

  Future<void> _join() async {
    final roomJid = _room.text.trim();
    final nick = _nick.text.trim();
    if (roomJid.isEmpty || nick.isEmpty) {
      setState(() => _error = 'Both the room address and a nickname are needed.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final db = ref.read(databaseProvider);
    final failure = await ref
        .read(xmppServiceProvider)
        .joinGroupChat(roomJid, nick);
    if (!mounted) return;
    setState(() => _busy = false);
    if (failure != null) {
      // Each of these needs a different sentence: "could not join" for a
      // nickname clash and for a password requirement leaves the user with
      // nothing to act on.
      setState(() => _error = _describe(failure));
      return;
    }
    await db.upsertChat(roomJid);
    if (!mounted) return;
    final navigator = Navigator.of(context);
    navigator.pop();
    navigator.pushNamed('/chat', arguments: roomJid);
  }

  /// One sentence per refusal.
  ///
  /// Matched on the error *type* rather than on its text: moxxmpp's own
  /// `toString()` is not a contract, and a message that has to be rewritten
  /// every time it changes is a message that will be wrong for one release.
  static String _describe(Object error) {
    if (error is NicknameTakenError) {
      return 'That nickname is taken in this room. Pick another.';
    }
    if (error is PasswordRequiredError) {
      return 'This room needs a password, which this client does not support '
          'yet.';
    }
    if (error is BannedFromRoomError) {
      return 'You are banned from this room.';
    }
    if (error is RoomFullError) {
      return 'This room is full.';
    }
    if (error is JoinForbiddenError) {
      return 'The room refused the join without saying why.';
    }
    if (error is NoNicknameSpecified) {
      return 'A nickname is required to join.';
    }
    if (error is RoomNotFoundError) {
      // The address is the likely mistake, and this is the one refusal where
      // that is almost certainly true.
      return 'That service has no room at that address. Group rooms look like '
          'room@conference.example.org.';
    }
    if (error is MucServiceUnresponsive) {
      // The most likely cause by far: an address that is not a group chat.
      // "Could not join" would leave the user with nothing to act on.
      return 'Nothing answered at that address. Check the room address — group '
          'rooms look like room@conference.example.org.';
    }
    return 'Could not join: $error';
  }

  @override
  Widget build(BuildContext context) {
    final tg = context.tg;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        16,
        20,
        MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Join a group', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          TextField(
            controller: _room,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Room address',
              hintText: 'room@conference.example.org',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _nick,
            decoration: const InputDecoration(
              labelText: 'Your nickname in this room',
              helperText: 'How everyone else in the room will see you.',
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: TextStyle(color: tg.danger, fontSize: 13),
            ),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : _join,
            child: Text(_busy ? 'Joining…' : 'Join'),
          ),
        ],
      ),
    );
  }
}

/// The member list.
///
/// Sorted moderators first, because they are the people whose role in a room
/// is not interchangeable: the first thing a user needs from this list is who
/// they can ask something of.
class MemberList extends StatelessWidget {
  const MemberList({super.key, required this.chat});

  final GroupChat chat;

  @override
  Widget build(BuildContext context) {
    final tg = context.tg;
    final sorted = [...chat.occupants]..sort((a, b) {
        if (a.isModerator != b.isModerator) return a.isModerator ? -1 : 1;
        return a.nick.toLowerCase().compareTo(b.nick.toLowerCase());
      });

    return ListView(
      shrinkWrap: true,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
          child: Text(
            '${chat.occupants.length} in the room',
            style: TextStyle(color: tg.textSecondary, fontSize: 13),
          ),
        ),
        for (final occupant in sorted)
          ListTile(
            dense: true,
            leading: Icon(
              occupant.isModerator ? Icons.shield : Icons.person_outline,
              size: 20,
              color: occupant.isModerator ? tg.accent : tg.textSecondary,
            ),
            title: Text(
              occupant.nick,
              style: TextStyle(
                fontWeight: occupant.nick == chat.nick
                    ? FontWeight.w700
                    : FontWeight.w400,
              ),
            ),
            subtitle: occupant.isModerator
                ? const Text('Moderator')
                : null,
            // Our own row is marked rather than disabled: tapping it to start a
            // private chat is reasonable, and greyed-out rows look broken.
            trailing: occupant.nick == chat.nick
                ? Text('you', style: TextStyle(color: tg.textSecondary))
                : null,
            onTap: occupant.nick == chat.nick
                ? null
                : () => Navigator.of(context).pop(occupant.nick),
          ),
      ],
    );
  }
}

/// The room's own sheet: who is in it, and a way out.
///
/// Returns the nickname of a member the user picked, so the caller can start a
/// private conversation with them. Returns 'leave' as a sentinel for the leave
/// button — a string overload is not elegant, but the alternative is a result
/// enum threaded through a modal sheet, and both callers are in this file.
Future<RoomSheetResult?> showRoomSheet(
  BuildContext context,
  GroupChat chat,
) {
  return showModalBottomSheet<RoomSheetResult>(
    context: context,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    chat.roomJid,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                TextButton(
                  onPressed: () =>
                      Navigator.of(context).pop(const RoomSheetResult.leave()),
                  child: const Text('Leave'),
                ),
              ],
            ),
          ),
          Flexible(child: MemberList(chat: chat)),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

/// What the room sheet produced.
class RoomSheetResult {
  const RoomSheetResult.leave() : nick = null;
  const RoomSheetResult.openPrivate(this.nick);

  /// A member's nickname to start a private conversation with, or null when the
  /// user chose to leave instead.
  final String? nick;

  bool get leaving => nick == null;
}

/// The pinned messages in a conversation.
///
/// Shows the text as it was when pinned rather than the live row: the pin is
/// about "this is the one that matters", and if the message is edited or
/// deleted afterwards the reader still needs to know which message was meant.
class PinnedSheet extends ConsumerWidget {
  const PinnedSheet({
    super.key,
    required this.chatJid,
    required this.pinnedIds,
    required this.bodies,
  });

  final String chatJid;

  /// Stanza ids, most recently pinned first.
  final List<String> pinnedIds;

  /// Text for each pinned id, keyed the same way.
  final Map<String, ({String body, String sender, DateTime at})> bodies;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tg = context.tg;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.5,
      builder: (context, controller) {
        if (pinnedIds.isEmpty) {
          return Center(
            child: Text(
              'Nothing pinned',
              style: TextStyle(color: tg.textSecondary),
            ),
          );
        }
        return ListView(
          controller: controller,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Text(
                'Pinned (${pinnedIds.length})',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            for (final id in pinnedIds)
              _pinnedTile(context, ref, tg, id),
          ],
        );
      },
    );
  }

  Widget _pinnedTile(
    BuildContext context,
    WidgetRef ref,
    dynamic tg,
    String id,
  ) {
    final entry = bodies[id];
    return Dismissible(
      key: ValueKey('pinned-$id'),
      direction: DismissDirection.endToStart,
      background: Container(
        color: tg.danger,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: const Icon(Icons.push_pin, color: Colors.white),
      ),
      confirmDismiss: (_) async {
        await togglePinned(ref, chatJid, id);
        return false;
      },
      child: ListTile(
        title: Text(
          entry?.body ?? '(no longer available)',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          entry == null
              ? 'This message was deleted.'
              : '${entry.sender} · ${_clock(entry.at)}',
          style: TextStyle(color: tg.textSecondary),
        ),
        onTap: () {
          Navigator.of(context).pop();
          Navigator.of(context).pushNamed('/chat', arguments: chatJid);
        },
      ),
    );
  }

  static String _clock(DateTime t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}
