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

  static String _describe(MUCError error) => switch (error.toString()) {
        String s when s.contains('nickname in use') || s.contains('409') =>
          'That nickname is taken in this room. Pick another.',
        String s when s.contains('password') || s.contains('auth') =>
          'This room needs a password, which this client does not support yet.',
        String s when s.contains('banned') =>
          'You are banned from this room.',
        String s when s.contains('max') || s.contains('503') =>
          'This room is full.',
        String s when s.contains('nickname') =>
          'A nickname is required to join.',
        _ => 'Could not join: $error',
      };

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
