// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Room profile page — description, subject/topic, encryption, notifications,
// members, leave/destroy. Shared blocks live in chat_profile_sections.dart.
//
// Description (`muc#roominfo_description` / `muc#roomconfig_roomdesc`) is not
// the subject: Conversations `Room.of` reads description from disco; subject is
// the live MUC topic. Symmetric with [ProfilePage]: tap the chat AppBar header
// to open.

import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../account/resolve.dart';
import '../../l10n/l10n.dart';
import '../../state/providers.dart';
import '../../xmpp/avatar.dart';
import '../../xmpp/connection.dart';
import '../../xmpp/local_nickname.dart';
import '../../xmpp/muc.dart';
import '../chat/chat_profile_sections.dart';
import '../contact_avatar.dart';
import '../theme.dart';
import 'invite_member_sheet.dart';
import 'occupant_actions.dart';
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
  String? _description;
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
      unawaited(_loadDescription());
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

  Future<void> _loadDescription() async {
    final desc = await _xmpp.queryRoomDescription(_roomJid);
    if (!mounted) return;
    setState(() => _description = desc);
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

  Future<void> _editDescription() async {
    final caps = _caps;
    if (caps == null || !caps.canConfigureRoom) return;
    final l10n = context.l10n;
    final controller = TextEditingController(text: _description ?? '');
    final next = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.editRoomDescription),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 4,
          decoration: InputDecoration(hintText: l10n.roomDescriptionHint),
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
    if (trimmed == (_description ?? '').trim()) return;
    final ok = await _xmpp.setRoomDescription(_roomJid, trimmed);
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.roomDescriptionSaveFailed)));
      return;
    }
    setState(() => _description = trimmed.isEmpty ? null : trimmed);
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(l10n.roomDescriptionSaved)));
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
    final ok = await showInviteMemberSheet(context, chatJid: widget.chatJid);
    if (!mounted || ok == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ok ? l10n.inviteSent : l10n.inviteFailed)),
    );
  }

  Future<void> _onOccupantTap(GroupChat room, Occupant occupant) async {
    final caps = _caps;
    if (caps == null) return;
    final nav = await runOccupantActions(
      context: context,
      ref: ref,
      chatKey: widget.chatJid,
      room: room,
      occupant: occupant,
      caps: caps,
      xmpp: _xmpp,
    );
    if (!mounted || nav == null) return;
    final jid = nav.privateChatJid;
    if (jid != null && jid.isNotEmpty) {
      _popResult(RoomProfileResult.openJidChat(jid));
      return;
    }
    final mucPm = nav.mucPmNick;
    if (mucPm != null && mucPm.isNotEmpty) {
      _popResult(RoomProfileResult.mucPm(mucPm));
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
    final desc = _description?.trim();
    final canEditDescription = caps?.canConfigureRoom ?? false;
    final subject = (_editedSubject ?? room?.subject)?.trim();
    final hasSubject = subject != null && subject.isNotEmpty;
    final canChangeSubject = caps?.canChangeSubject ?? false;

    final rosterGroups = groupOccupantsForRoster(room?.occupants ?? const []);

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

                _section(tg, l10n.roomDescription),
                ListTile(
                  title: Text(
                    (desc != null && desc.isNotEmpty)
                        ? desc
                        : (canEditDescription
                              ? l10n.editRoomDescription
                              : l10n.roomDescriptionHint),
                    style: TextStyle(
                      color: (desc != null && desc.isNotEmpty)
                          ? tg.textPrimary
                          : tg.textSecondary,
                      fontStyle: (desc != null && desc.isNotEmpty)
                          ? FontStyle.normal
                          : FontStyle.italic,
                    ),
                  ),
                  trailing: canEditDescription
                      ? const Icon(Icons.chevron_right)
                      : null,
                  onTap: canEditDescription
                      ? () => unawaited(_editDescription())
                      : null,
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

                ChatEncryptionSection(chatJid: widget.chatJid),
                ChatNotifySection(chatJid: widget.chatJid),

                _section(
                  tg,
                  _loadingCaps || room == null
                      ? l10n.members
                      : (room.canSeeMemberJids
                            ? l10n.membersAndOnlineCount(
                                room.affiliatedMemberCount,
                                room.onlineOccupantCount,
                              )
                            : l10n.membersOnlineCount(
                                room.onlineOccupantCount,
                              )),
                ),
                for (final entry in rosterGroups.entries) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Text(
                      _mucGroupLabel(l10n, entry.key),
                      style: TextStyle(
                        color: tg.textSecondary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                    child: Wrap(
                      alignment: WrapAlignment.start,
                      children: [
                        for (final occupant in entry.value)
                          _occupantCell(
                            tg: tg,
                            l10n: l10n,
                            room: room,
                            occupant: occupant,
                          ),
                      ],
                    ),
                  ),
                ],

                _section(tg, l10n.actions),
                ChatHistoryActions(chatJid: widget.chatJid),
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

  /// Gajim roster section titles (`get_uf_affiliation` / `get_uf_role` plural).
  static String _mucGroupLabel(AppLocalizations l10n, String key) {
    switch (key) {
      case 'owner':
        return l10n.roomOwners;
      case 'admin':
        return l10n.roomAdmins;
      case 'moderator':
        return l10n.roomModerators;
      case 'participant':
        return l10n.roomParticipants;
      case 'visitor':
        return l10n.roomVisitors;
      default:
        return key;
    }
  }

  /// Avatar + nick cell (matrix roster). Tap opens the same member sheet as
  /// the old list row.
  Widget _occupantCell({
    required TgColors tg,
    required AppLocalizations l10n,
    required GroupChat? room,
    required Occupant occupant,
  }) {
    final isSelf = occupant.nick == room?.nick;
    final avatarJid = (occupant.realJid != null && occupant.realJid!.isNotEmpty)
        ? occupant.realJid!
        : '$_roomJid/${occupant.nick}';
    return SizedBox(
      width: 76,
      child: InkWell(
        onTap: isSelf || room == null
            ? null
            : () => unawaited(_onOccupantTap(room, occupant)),
        onLongPress: isSelf || room == null
            ? null
            : () => unawaited(_onOccupantTap(room, occupant)),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ContactAvatar(
                // Real bare JID → PEP; else room/nick → occupant vCard
                // (Gajim GroupchatParticipant — never bare the room).
                jid: avatarJid,
                title: occupant.nick,
                radius: 28,
                showPresence: true,
                presence: occupant.presenceForDot,
              ),
              const SizedBox(height: 6),
              Text(
                occupant.nick,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: isSelf ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
              if (isSelf)
                Text(
                  l10n.you,
                  style: TextStyle(fontSize: 11, color: tg.textSecondary),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
