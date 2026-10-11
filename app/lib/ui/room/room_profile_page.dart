// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Room profile page — subject, notification mode, members, leave/destroy.
//
// Symmetric with [ProfilePage]: tap the chat AppBar header to open. A bottom
// sheet was wrong for the same reason a contact profile is a route:
// leave/destroy/kick need a full page, and notification settings belong next
// to the other room controls, not in the chat chrome.

import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../account/resolve.dart';
import '../../l10n/l10n.dart';
import '../../state/providers.dart';
import '../../store/database.dart';
import '../../xmpp/avatar.dart';
import '../../xmpp/connection.dart';
import '../../xmpp/local_nickname.dart';
import '../../xmpp/muc.dart';
import '../chats/notify_mode_sheet.dart';
import '../contact_avatar.dart';
import '../theme.dart';
import 'room_config_page.dart';

/// What [RoomProfilePage] produced for the chat page.
class RoomProfileResult {
  const RoomProfileResult.leave()
    : leaving = true,
      destroyed = false,
      jid = null,
      mucPmNick = null;

  const RoomProfileResult.destroy()
    : leaving = true,
      destroyed = true,
      jid = null,
      mucPmNick = null;

  const RoomProfileResult.openJidChat(this.jid)
    : leaving = false,
      destroyed = false,
      mucPmNick = null;

  const RoomProfileResult.mucPm(this.mucPmNick)
    : leaving = false,
      destroyed = false,
      jid = null;

  final bool leaving;

  /// Owner destroyed the room on the server (Conversations destroyRoom).
  final bool destroyed;

  /// Bare real JID for a 1:1 chat (non-anonymous rooms).
  final String? jid;

  /// Occupant nick for in-room private message (Conversations nextCounterpart).
  final String? mucPmNick;
}

enum _MemberAction { openJid, mucPm, kick }

class RoomProfilePage extends ConsumerStatefulWidget {
  const RoomProfilePage({super.key, required this.chatJid});

  /// [ChatRef.key] (or legacy bare JID), same as [ProfilePage.chatJid].
  final String chatJid;

  @override
  ConsumerState<RoomProfilePage> createState() => _RoomProfilePageState();
}

class _RoomProfilePageState extends ConsumerState<RoomProfilePage> {
  RoomSelfCapabilities? _caps;
  bool _loadingCaps = true;
  String? _roomTitle;
  String? _editedSubject;
  Uint8List? _avatarPreview;
  bool _avatarBusy = false;

  String get _roomJid => resolveChatKey(widget.chatJid).jid;

  XmppService get _xmpp => resolveChatKey(widget.chatJid).session.xmpp;

  @override
  void initState() {
    super.initState();
    unawaited(_loadCaps());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_loadTitle());
    });
  }

  Future<void> _loadCaps() async {
    final caps = await _xmpp.roomSelfCapabilities(_roomJid);
    if (!mounted) return;
    setState(() {
      _caps = caps;
      _loadingCaps = false;
    });
  }

  Future<void> _loadTitle() async {
    final chat = ref.read(chatProvider(widget.chatJid)).value;
    if (!mounted) return;
    final t = chat?.title.trim();
    if (t != null && t.isNotEmpty && t != _roomJid) {
      setState(() => _roomTitle = t);
    }
  }

  void _popResult(RoomProfileResult result) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(context).pop(result);
    });
  }

  Future<void> _confirmDestroy() async {
    final caps = _caps;
    if (caps == null || !caps.canConfigureRoom) return;
    final l10n = context.l10n;
    final tg = context.tg;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.destroyRoom),
        content: Text(l10n.destroyRoomConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.destroyRoom, style: TextStyle(color: tg.danger)),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      Navigator.of(context).pop(const RoomProfileResult.destroy());
    }
  }

  Future<void> _editRoomName() async {
    final caps = _caps;
    if (caps == null || !caps.canConfigureRoom) return;
    final l10n = context.l10n;
    final controller = TextEditingController(text: _roomTitle ?? '');
    final next = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.editRoomName),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: l10n.roomNameHint),
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
    await WidgetsBinding.instance.endOfFrame;
    controller.dispose();
    if (next == null || !mounted) return;
    final trimmed = next.trim();
    final ok = await _xmpp.setRoomName(_roomJid, trimmed);
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.roomNameSaveFailed)));
      return;
    }
    final db = resolveChatKey(widget.chatJid).session.db;
    await db.upsertChat(
      _roomJid,
      isGroup: true,
      title: trimmed.isEmpty ? _roomJid : trimmed,
    );
    if (!mounted) return;
    setState(() => _roomTitle = trimmed.isEmpty ? null : trimmed);
    ref.invalidate(chatProvider(widget.chatJid));
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(l10n.roomNameSaved)));
  }

  Future<void> _pickRoomAvatar() async {
    final caps = _caps;
    if (caps == null || !caps.canConfigureRoom) return;
    final l10n = context.l10n;
    final picked = await FilePicker.pickFile(type: FileType.image);
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    if (bytes.isEmpty) return;
    setState(() {
      _avatarBusy = true;
      _avatarPreview = bytes;
    });
    final ok = await _xmpp.publishMucAvatar(_roomJid, bytes);
    if (!mounted) return;
    setState(() => _avatarBusy = false);
    if (ok) {
      final prepared = await prepareAvatarImage(bytes);
      if (!mounted) return;
      if (prepared != null) {
        seedAvatarCache(_roomJid, prepared.bytes);
        ref.read(avatarRevisionProvider.notifier).state++;
      }
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.avatarPublished)));
    } else {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.avatarPublishFailed)));
    }
  }

  Future<void> _editSubject(String? current) async {
    final caps = _caps;
    if (caps == null || !caps.canChangeSubject) return;
    final l10n = context.l10n;
    final controller = TextEditingController(text: current ?? '');
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
    await WidgetsBinding.instance.endOfFrame;
    controller.dispose();
    if (next == null || !mounted) return;
    final trimmed = next.trim();
    if (trimmed == (current ?? '').trim()) return;
    await _xmpp.setGroupChatSubject(_roomJid, trimmed);
    if (!mounted) return;
    setState(() => _editedSubject = trimmed);
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
    final ok = await _xmpp.inviteToRoom(_roomJid, jid);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ok ? l10n.inviteSent : l10n.inviteFailed)),
    );
  }

  Future<void> _onOccupantTap(GroupChat room, Occupant occupant) async {
    if (occupant.nick == room.nick) return;
    final caps = _caps;
    if (caps == null) return;
    final l10n = context.l10n;
    final tg = context.tg;

    final realJid = occupant.realJid;
    final nonAnon =
        caps.privateNonAnonymous && realJid != null && realJid.isNotEmpty;
    final canOpenJid = nonAnon;
    final canMucPm =
        !nonAnon &&
        caps.allowPm &&
        occupant.isOnline &&
        occupant.nick.isNotEmpty;
    final canKick = caps.canKick(occupant);

    if (!canOpenJid && !canMucPm && !canKick) return;

    final action = await showModalBottomSheet<_MemberAction>(
      context: context,
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
        _popResult(RoomProfileResult.openJidChat(realJid!));
        return;
      case _MemberAction.mucPm:
        _popResult(RoomProfileResult.mucPm(occupant.nick));
        return;
      case _MemberAction.kick:
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
        final ok = await _xmpp.kickOccupant(_roomJid, occupant);
        if (!mounted) return;
        if (ok) ref.invalidate(roomStateProvider(widget.chatJid));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ok ? l10n.kickSucceeded : l10n.kickFailed)),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final tg = context.tg;
    final l10n = context.l10n;
    final chatRow = ref.watch(chatProvider(widget.chatJid)).value;
    final roomAsync = ref.watch(roomStateProvider(widget.chatJid));
    final room = roomAsync.value;
    final caps = _caps;

    final storedTitle = chatRow?.title ?? '';
    final title = displayName(
      localNickname: null,
      rosterTitle: storedTitle,
      roomTitle: storedTitle.isNotEmpty ? storedTitle : (_roomTitle ?? ''),
      jid: _roomJid,
      isRoom: true,
    );
    final subject = (_editedSubject ?? room?.subject)?.trim();
    final hasSubject = subject != null && subject.isNotEmpty;
    final canChangeSubject = caps?.canChangeSubject ?? false;

    final occupants = [...?room?.occupants]
      ..sort((a, b) {
        if (a.isModerator != b.isModerator) return a.isModerator ? -1 : 1;
        return a.nick.toLowerCase().compareTo(b.nick.toLowerCase());
      });

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: roomAsync.isLoading && room == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 20),
                  child: Column(
                    children: [
                      Padding(
                        padding: (caps?.canConfigureRoom ?? false)
                            ? avatarCameraBadgePadding(44)
                            : EdgeInsets.zero,
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            _avatarPreview != null
                                ? ClipOval(
                                    child: Image.memory(
                                      _avatarPreview!,
                                      width: 88,
                                      height: 88,
                                      fit: BoxFit.cover,
                                    ),
                                  )
                                : ContactAvatar(
                                    jid: _roomJid,
                                    title: title,
                                    radius: 44,
                                  ),
                            if ((caps?.canConfigureRoom ?? false) &&
                                !_avatarBusy)
                              AvatarCameraBadge(
                                avatarRadius: 44,
                                tooltip: l10n.changeAvatar,
                                onPressed: () => unawaited(_pickRoomAvatar()),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              title,
                              textAlign: TextAlign.center,
                              style: const TextStyle(fontSize: 20),
                            ),
                          ),
                          if (caps?.canConfigureRoom ?? false)
                            IconButton(
                              tooltip: l10n.editRoomName,
                              visualDensity: VisualDensity.compact,
                              onPressed: () => unawaited(_editRoomName()),
                              icon: Icon(
                                Icons.edit_outlined,
                                size: 18,
                                color: tg.textSecondary,
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _roomJid,
                        style: TextStyle(fontSize: 14, color: tg.textSecondary),
                      ),
                    ],
                  ),
                ),

                _section(tg, l10n.subjectHint),
                ListTile(
                  title: Text(
                    hasSubject
                        ? subject
                        : (canChangeSubject
                              ? l10n.editSubject
                              : l10n.subjectHint),
                    style: TextStyle(
                      color: hasSubject ? tg.textPrimary : tg.textSecondary,
                      fontStyle: hasSubject
                          ? FontStyle.normal
                          : FontStyle.italic,
                    ),
                  ),
                  trailing: canChangeSubject
                      ? const Icon(Icons.chevron_right)
                      : null,
                  onTap: canChangeSubject
                      ? () => unawaited(_editSubject(subject))
                      : null,
                ),

                _section(tg, l10n.notificationSettings),
                if (chatRow != null)
                  ListTile(
                    leading: Icon(
                      notifyModeIcon(
                        chatNotifyModeOf(
                          muted: chatRow.muted,
                          alwaysNotify: chatRow.alwaysNotify,
                        ),
                      ),
                    ),
                    title: Text(l10n.notificationSettings),
                    subtitle: Text(
                      notifyModeLabel(
                        l10n,
                        chatNotifyModeOf(
                          muted: chatRow.muted,
                          alwaysNotify: chatRow.alwaysNotify,
                        ),
                      ),
                    ),
                    onTap: () =>
                        openChatNotifySettings(context, widget.chatJid),
                  ),

                _section(
                  tg,
                  _loadingCaps
                      ? l10n.members
                      : l10n.membersInRoom(occupants.length),
                ),
                for (final occupant in occupants)
                  ListTile(
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
                        fontWeight: occupant.nick == room?.nick
                            ? FontWeight.w700
                            : FontWeight.w400,
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
                    trailing: occupant.nick == room?.nick
                        ? Text(
                            l10n.you,
                            style: TextStyle(color: tg.textSecondary),
                          )
                        : null,
                    onTap: occupant.nick == room?.nick || room == null
                        ? null
                        : () => unawaited(_onOccupantTap(room, occupant)),
                  ),

                _section(tg, l10n.actions),
                if (caps?.canInvite ?? false)
                  ListTile(
                    leading: const Icon(Icons.person_add_outlined),
                    title: Text(l10n.inviteMember),
                    onTap: () => unawaited(_invite()),
                  ),
                if (caps?.canConfigureRoom ?? false)
                  ListTile(
                    leading: const Icon(Icons.tune),
                    title: Text(l10n.roomConfiguration),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      Navigator.of(context).push<void>(
                        MaterialPageRoute<void>(
                          builder: (_) =>
                              RoomConfigPage(chatKey: widget.chatJid),
                        ),
                      );
                    },
                  ),
                ListTile(
                  leading: Icon(Icons.logout, color: tg.danger),
                  title: Text(
                    l10n.leaveRoom,
                    style: TextStyle(color: tg.danger),
                  ),
                  onTap: () =>
                      Navigator.of(context)
                          .pop(const RoomProfileResult.leave()),
                ),
                if (caps?.canConfigureRoom ?? false)
                  ListTile(
                    leading: Icon(Icons.delete_forever, color: tg.danger),
                    title: Text(
                      l10n.destroyRoom,
                      style: TextStyle(color: tg.danger),
                    ),
                    onTap: () => unawaited(_confirmDestroy()),
                  ),
                const SizedBox(height: 24),
              ],
            ),
    );
  }

  Widget _section(TgColors tg, String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        label,
        style: TextStyle(
          color: tg.textSecondary,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
