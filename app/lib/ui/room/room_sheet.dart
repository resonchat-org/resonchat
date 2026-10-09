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

import '../../account/account_hub.dart';
import '../../account/chat_ref.dart';
import '../../l10n/l10n.dart';
import '../../state/providers.dart';
import '../../store/database.dart';
import '../../xmpp/connection.dart';
import '../../xmpp/muc.dart';
import 'room_config_page.dart';
import '../chats/notify_mode_sheet.dart';
import '../home/open_chat.dart';
import '../theme.dart';

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
      setState(() => _error = context.l10n.joinRoomNeedBoth);
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
      setState(() => _error = _describe(context.l10n, failure));
      return;
    }
    // MODE_MULTI: persist as a room with nick — never as a roster contact.
    // Disco decides Conversations isPrivateAndNonAnonymous (OMEMO allowed).
    final xmpp = ref.read(xmppServiceProvider);
    final features = await xmpp.queryRoomFeatures(roomJid);
    final encryptable = isPrivateAndNonAnonymous(features);
    // Conversations fetchMembers after join when private+non-anonymous.
    await xmpp.refreshRoomMembership(roomJid, privateNonAnonymous: encryptable);
    await db.upsertChat(
      roomJid,
      isGroup: true,
      mucNick: nick,
      title: roomJid,
      mucPrivateNonAnonymous: encryptable,
    );
    if (!mounted) return;
    final accountId = accountHub.primarySession?.account.id;
    final chatKey = accountId == null
        ? roomJid
        : ChatRef(accountId: accountId, jid: roomJid).key;
    openChat(context, chatKey);
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
          TextField(
            controller: _room,
            autofocus: true,
            decoration: InputDecoration(
              labelText: l10n.roomAddress,
              hintText: l10n.roomAddressHint,
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
            onPressed: _busy ? null : _join,
            child: Text(_busy ? l10n.joining : l10n.join),
          ),
        ],
      ),
    );
  }
}

/// The room's own sheet: about (Subject), members, invite, and a way out.
///
/// Member tap follows Telegram `ProfileActivity.onMemberClick` (action sheet),
/// with Conversations gates for kick / invite / JID chat / in-room PM.
Future<RoomSheetResult?> showRoomSheet(
  BuildContext context,
  GroupChat chat, {
  required String chatKey,
  required XmppService xmpp,
  RoomSelfCapabilities? caps,
  bool canChangeSubject = false,
  Future<void> Function(String subject)? onSetSubject,
}) {
  return showModalBottomSheet<RoomSheetResult>(
    context: context,
    isScrollControlled: true,
    builder: (context) => _RoomSheet(
      chat: chat,
      chatKey: chatKey,
      xmpp: xmpp,
      caps: caps,
      canChangeSubject: canChangeSubject,
      onSetSubject: onSetSubject,
    ),
  );
}

class _RoomSheet extends StatefulWidget {
  const _RoomSheet({
    required this.chat,
    required this.chatKey,
    required this.xmpp,
    this.caps,
    required this.canChangeSubject,
    this.onSetSubject,
  });

  final GroupChat chat;
  final String chatKey;
  final XmppService xmpp;
  final RoomSelfCapabilities? caps;
  final bool canChangeSubject;
  final Future<void> Function(String subject)? onSetSubject;

  @override
  State<_RoomSheet> createState() => _RoomSheetState();
}

class _RoomSheetState extends State<_RoomSheet> {
  late String? _subject = widget.chat.subject;
  late List<Occupant> _occupants = List.of(widget.chat.occupants);
  late RoomSelfCapabilities? _caps = widget.caps;
  bool _loadingCaps = false;

  @override
  void initState() {
    super.initState();
    if (_caps == null) {
      _loadingCaps = true;
      widget.xmpp.roomSelfCapabilities(widget.chat.roomJid).then((c) {
        if (!mounted) return;
        setState(() {
          _caps = c;
          _loadingCaps = false;
        });
      });
    }
  }

  Future<void> _editSubject() async {
    if (!widget.canChangeSubject || widget.onSetSubject == null) return;
    final l10n = context.l10n;
    final controller = TextEditingController(text: _subject ?? '');
    final next = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.editSubject),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 4,
          decoration: InputDecoration(hintText: l10n.subjectHint),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: Text(l10n.save),
          ),
        ],
      ),
    );
    // Dialog route may still hold the field for one frame.
    await WidgetsBinding.instance.endOfFrame;
    controller.dispose();
    if (next == null || !mounted) return;
    final trimmed = next.trim();
    if (trimmed == (_subject ?? '').trim()) return;
    await widget.onSetSubject!(trimmed);
    if (!mounted) return;
    setState(() => _subject = trimmed);
  }

  Future<void> _invite() async {
    final caps = _caps;
    if (caps == null || !caps.canInvite) return;
    final l10n = context.l10n;
    final controller = TextEditingController();
    final jid = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.inviteMember),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.emailAddress,
          decoration: InputDecoration(hintText: l10n.inviteMemberHint),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: Text(l10n.inviteMember),
          ),
        ],
      ),
    );
    await WidgetsBinding.instance.endOfFrame;
    controller.dispose();
    if (jid == null || jid.isEmpty || !mounted) return;
    final ok = await widget.xmpp.inviteToRoom(widget.chat.roomJid, jid);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ok ? l10n.inviteSent : l10n.inviteFailed)),
    );
  }

  /// Pop this room sheet on the next frame.
  ///
  /// Nested sheets/dialogs must finish tearing down InheritedWidgets
  /// (Theme / Localizations) before we deactivate this route — otherwise
  /// Flutter asserts `_dependents.isEmpty`.
  void _popRoomSheet(RoomSheetResult result) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(context).pop(result);
    });
  }

  Future<void> _onOccupantTap(Occupant occupant) async {
    if (occupant.nick == widget.chat.nick) return;
    final caps = _caps;
    if (caps == null) return;
    final l10n = context.l10n;
    final tg = context.tg;

    final realJid = occupant.realJid;
    final nonAnon =
        caps.privateNonAnonymous && realJid != null && realJid.isNotEmpty;
    // Conversations: real JID → start_conversation; anonymous / public →
    // send_private_message when allowPm and the target is present.
    final canOpenJid = nonAnon;
    final canMucPm =
        !nonAnon &&
        caps.allowPm &&
        occupant.isOnline &&
        occupant.nick.isNotEmpty;
    final canKick = caps.canKick(occupant);

    if (!canOpenJid && !canMucPm && !canKick) return;

    // Telegram ProfileActivity.onMemberClick → ItemOptions sheet.
    // useRootNavigator: avoid nesting under the room sheet's route (that
    // pairing trips InheritedWidget `_dependents.isEmpty` on pop).
    final action = await showModalBottomSheet<_MemberAction>(
      context: context,
      useRootNavigator: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(occupant.nick),
              subtitle: realJid != null && realJid.isNotEmpty
                  ? Text(realJid, style: TextStyle(color: tg.textSecondary))
                  : null,
            ),
            if (canOpenJid)
              ListTile(
                leading: const Icon(Icons.chat_bubble_outline),
                title: Text(l10n.sendMessage),
                onTap: () => Navigator.pop(sheetContext, _MemberAction.openJid),
              ),
            if (canMucPm)
              ListTile(
                leading: const Icon(Icons.lock_outline),
                title: Text(l10n.privateMessageInRoom),
                onTap: () => Navigator.pop(sheetContext, _MemberAction.mucPm),
              ),
            if (canKick)
              ListTile(
                leading: Icon(Icons.person_remove_outlined, color: tg.danger),
                title: Text(
                  l10n.kickFromRoom,
                  style: TextStyle(color: tg.danger),
                ),
                onTap: () => Navigator.pop(sheetContext, _MemberAction.kick),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;

    switch (action) {
      case _MemberAction.openJid:
        _popRoomSheet(RoomSheetResult.openJidChat(realJid!));
        return;
      case _MemberAction.mucPm:
        _popRoomSheet(RoomSheetResult.mucPm(occupant.nick));
        return;
      case _MemberAction.kick:
        // Action sheet may still be animating out — wait one frame.
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted) return;
        final confirm = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(l10n.kickFromRoom),
            content: Text(l10n.kickFromRoomConfirm(occupant.nick)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: Text(l10n.cancel),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text(
                  l10n.kickFromRoom,
                  style: TextStyle(color: tg.danger),
                ),
              ),
            ],
          ),
        );
        if (confirm != true || !mounted) return;
        final ok = await widget.xmpp.kickOccupant(
          widget.chat.roomJid,
          occupant,
        );
        if (!mounted) return;
        if (ok) {
          setState(() {
            _occupants = [
              for (final o in _occupants)
                if (o.nick != occupant.nick) o,
            ];
          });
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ok ? l10n.kickSucceeded : l10n.kickFailed)),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final tg = context.tg;
    final l10n = context.l10n;
    final subject = _subject?.trim();
    final hasSubject = subject != null && subject.isNotEmpty;
    final caps = _caps;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.75;

    final sorted = [..._occupants]
      ..sort((a, b) {
        if (a.isModerator != b.isModerator) return a.isModerator ? -1 : 1;
        return a.nick.toLowerCase().compareTo(b.nick.toLowerCase());
      });

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.chat.roomJid,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  if (caps?.canInvite ?? false)
                    IconButton(
                      tooltip: l10n.inviteMember,
                      onPressed: _invite,
                      icon: const Icon(Icons.person_add_outlined),
                    ),
                  if (caps?.canConfigureRoom ?? false)
                    IconButton(
                      tooltip: l10n.roomConfiguration,
                      onPressed: () {
                        Navigator.of(context).push<void>(
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                RoomConfigPage(chatKey: widget.chatKey),
                          ),
                        );
                      },
                      icon: const Icon(Icons.tune),
                    ),
                  TextButton(
                    onPressed: () =>
                        Navigator.of(context)
                            .pop(const RoomSheetResult.leave()),
                    child: Text(l10n.leaveRoom),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: InkWell(
                onTap: widget.canChangeSubject ? _editSubject : null,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.subjectHint,
                        style: TextStyle(color: tg.textSecondary, fontSize: 12),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        hasSubject
                            ? subject
                            : (widget.canChangeSubject
                                  ? l10n.editSubject
                                  : l10n.subjectHint),
                        style: TextStyle(
                          color: hasSubject ? tg.textPrimary : tg.textSecondary,
                          fontSize: 15,
                          fontStyle: hasSubject
                              ? FontStyle.normal
                              : FontStyle.italic,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            _RoomNotifyTile(chatKey: widget.chatKey),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
              child: Text(
                _loadingCaps ? l10n.members : l10n.membersInRoom(sorted.length),
                style: TextStyle(color: tg.textSecondary, fontSize: 13),
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: sorted.length,
                itemBuilder: (context, i) {
                  final occupant = sorted[i];
                  final isSelf = occupant.nick == widget.chat.nick;
                  return ListTile(
                    dense: true,
                    leading: Icon(
                      occupant.isModerator
                          ? Icons.shield
                          : Icons.person_outline,
                      size: 20,
                      color: occupant.isModerator
                          ? tg.accent
                          : tg.textSecondary,
                    ),
                    title: Text(
                      occupant.nick,
                      style: TextStyle(
                        fontWeight: isSelf ? FontWeight.w700 : FontWeight.w400,
                      ),
                    ),
                    subtitle: occupant.isModerator
                        ? Text(l10n.moderator)
                        : (occupant.realJid != null &&
                                  occupant.realJid!.isNotEmpty
                              ? Text(
                                  occupant.realJid!,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                )
                              : null),
                    trailing: isSelf
                        ? Text(
                            l10n.you,
                            style: TextStyle(color: tg.textSecondary),
                          )
                        : null,
                    onTap: isSelf ? null : () => _onOccupantTap(occupant),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _MemberAction { openJid, mucPm, kick }

/// What the room sheet produced for the chat page.
class RoomSheetResult {
  const RoomSheetResult.leave() : leaving = true, jid = null, mucPmNick = null;

  const RoomSheetResult.openJidChat(this.jid)
    : leaving = false,
      mucPmNick = null;

  const RoomSheetResult.mucPm(this.mucPmNick) : leaving = false, jid = null;

  final bool leaving;

  /// Bare real JID for a 1:1 chat (non-anonymous rooms).
  final String? jid;

  /// Occupant nick for in-room private message (Conversations nextCounterpart).
  final String? mucPmNick;
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

/// Notification mode row in the room sheet.
class _RoomNotifyTile extends ConsumerWidget {
  const _RoomNotifyTile({required this.chatKey});

  final String chatKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final chat = ref.watch(chatProvider(chatKey)).value;
    if (chat == null) return const SizedBox.shrink();
    final mode = chatNotifyModeOf(
      muted: chat.muted,
      alwaysNotify: chat.alwaysNotify,
    );
    return ListTile(
      leading: Icon(notifyModeIcon(mode)),
      title: Text(l10n.notificationSettings),
      subtitle: Text(notifyModeLabel(l10n, mode)),
      onTap: () => openChatNotifySettings(context, chatKey),
    );
  }
}
