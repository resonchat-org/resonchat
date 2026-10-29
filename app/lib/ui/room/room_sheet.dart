// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Join-room sheet and the pinned-messages sheet.
//
// Room *profile* lives on [RoomProfilePage] (mirrors [ProfilePage]).
// Joining still belongs in a sheet: it is a short form, not a destination.

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:moxxmpp/moxxmpp.dart';

import 'package:resonchat/account/account_hub.dart';
import 'package:resonchat/account/chat_ref.dart';
import 'package:resonchat/l10n/l10n.dart';
import 'package:resonchat/state/providers.dart';
import 'package:resonchat/ui/accounts/account_action_picker.dart';
import 'package:resonchat/ui/home/open_chat.dart';
import 'package:resonchat/ui/theme.dart';
import 'package:resonchat/xmpp/jid_input.dart';
import 'package:resonchat/xmpp/muc/muc.dart';

/// Asks for a room JID and a nickname, then joins.
/// Shows the join-room sheet, optionally prefilled from an `xmpp:?join` URI.
Future<void> showJoinRoomSheet(
  BuildContext context, {
  String? initialRoomJid,
  String? accountId,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => JoinRoomSheet(
      initialRoomJid: initialRoomJid,
      initialAccountId: accountId,
    ),
  );
}

class JoinRoomSheet extends ConsumerStatefulWidget {
  const JoinRoomSheet({super.key, this.initialRoomJid, this.initialAccountId});

  /// Bare room JID from an `xmpp:room@muc.example?join` link.
  final String? initialRoomJid;

  /// Prefill when the contacts filter already selected an account.
  final String? initialAccountId;

  @override
  ConsumerState<JoinRoomSheet> createState() => _JoinRoomSheetState();
}

class _JoinRoomSheetState extends ConsumerState<JoinRoomSheet> {
  final _room = TextEditingController();
  final _nick = TextEditingController();
  String? _accountId;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _accountId = defaultActionAccountId(preferred: widget.initialAccountId);
    _applyNickFromAccount();
    final prefill = widget.initialRoomJid?.trim();
    if (prefill != null && prefill.isNotEmpty) {
      _room.text = prefill;
    }
    _room.addListener(() => setState(() {}));
    _nick.addListener(() => setState(() {}));
  }

  void _applyNickFromAccount() {
    final id = _accountId;
    final session = id == null ? null : accountHub.session(id);
    final bare = session?.account.bareJid ?? '';
    final local = bare.contains('@') ? bare.split('@').first : bare;
    if (local.isNotEmpty) _nick.text = local;
  }

  @override
  void dispose() {
    _room.dispose();
    _nick.dispose();
    super.dispose();
  }

  Future<void> _join() async {
    final roomJid = completeJidCandidate(_room.text);
    final nick = _nick.text.trim();
    if (roomJid == null || nick.isEmpty) {
      setState(() => _error = context.l10n.joinRoomNeedBoth);
      return;
    }
    final session = _accountId == null ? null : accountHub.session(_accountId!);
    if (session == null) {
      setState(() => _error = context.l10n.noAccountReady);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final xmpp = session.xmpp;
    final db = session.db;
    final failure = await xmpp.joinGroupChat(roomJid, nick);
    if (!mounted) return;
    setState(() => _busy = false);
    if (failure != null) {
      // Each of these needs a different sentence: "could not join" for a
      // nickname clash and for a password requirement leaves the user with
      // nothing to act on.
      setState(() => _error = _describe(context.l10n, failure));
      return;
    }
    // MODE_MULTI: persist as a room with nick — never as a roster contact.
    // Disco decides Conversations isPrivateAndNonAnonymous (OMEMO allowed).
    final features = await xmpp.queryRoomFeatures(roomJid);
    final encryptable = isPrivateAndNonAnonymous(features);
    await xmpp.refreshRoomMembership(
      roomJid,
      privateNonAnonymous: encryptable,
      nonAnonymous: isNonAnonymousRoom(features),
    );
    await db.upsertChat(
      roomJid,
      isGroup: true,
      mucNick: nick,
      title: roomJid,
      mucPrivateNonAnonymous: encryptable,
    );
    // Conversations: rooms are MODE_MULTI + bookmarks, never roster contacts.
    await xmpp.removeFromRosterIfPresent(roomJid);
    unawaited(xmpp.publishConferenceBookmark(roomJid: roomJid, nick: nick));
    if (!mounted) return;
    openChat(context, ChatRef(accountId: session.account.id, jid: roomJid).key);
  }

  /// One sentence per refusal.
  ///
  /// Matched on the error *type* rather than on its text: moxxmpp's own
  /// `toString()` is not a contract, and a message that has to be rewritten
  /// every time it changes is a message that will be wrong for one release.
  static String _describe(AppLocalizations l10n, Object error) {
    if (error is NicknameTakenError) return l10n.nicknameTaken;
    if (error is PasswordRequiredError) return l10n.roomNeedsPassword;
    if (error is BannedFromRoomError) return l10n.bannedFromRoom;
    if (error is RoomFullError) return l10n.roomFull;
    if (error is JoinForbiddenError) return l10n.joinForbidden;
    if (error is NoNicknameSpecified) return l10n.nicknameRequired;
    if (error is RoomNotFoundError) return l10n.roomNotFound;
    if (error is MucServiceUnresponsive) return l10n.mucUnresponsive;
    return l10n.couldNotJoin('$error');
  }

  @override
  Widget build(BuildContext context) {
    final tg = context.tg;
    final l10n = context.l10n;
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
          Text(l10n.joinGroup, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          AccountActionPicker(
            selectedId: _accountId,
            enabled: !_busy,
            onChanged: (id) {
              setState(() {
                _accountId = id;
                _applyNickFromAccount();
              });
            },
          ),
          TextField(
            controller: _room,
            autofocus: true,
            decoration: InputDecoration(
              labelText: l10n.roomAddress,
              hintText: l10n.roomAddressHint,
              errorText:
                  _room.text.trim().isNotEmpty &&
                      completeJidCandidate(_room.text) == null
                  ? l10n.invalidJid
                  : null,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _nick,
            decoration: InputDecoration(
              labelText: l10n.yourNicknameInRoom,
              helperText: l10n.nicknameHelper,
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: tg.danger, fontSize: 13)),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed:
                _busy ||
                    completeJidCandidate(_room.text) == null ||
                    _nick.text.trim().isEmpty
                ? null
                : _join,
            child: Text(_busy ? l10n.joining : l10n.join),
          ),
        ],
      ),
    );
  }
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
            for (final id in pinnedIds) _pinnedTile(context, ref, tg, id),
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
          openChat(context, chatJid);
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
