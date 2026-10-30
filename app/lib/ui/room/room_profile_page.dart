// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Room profile page — description, subject/topic, encryption, notifications,
// members, leave/destroy. Shared blocks live in chat_profile_sections.dart.
//
// Description (`muc#roominfo_description` / `muc#roomconfig_roomdesc`) is not
// the subject: Conversations `Room.of` reads description from disco; subject is
// the live MUC topic. Symmetric with [ProfilePage]: open from the chat AppBar ⋮.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:resonchat/account/resolve.dart';
import 'package:resonchat/l10n/l10n.dart';
import 'package:resonchat/state/providers.dart';
import 'package:resonchat/ui/accounts/account_qr_code.dart';
import 'package:resonchat/ui/chat/auto_translate_sheet.dart';
import 'package:resonchat/ui/chat/chat_profile_sections.dart';
import 'package:resonchat/ui/contact_avatar.dart';
import 'package:resonchat/ui/room/invite_member_sheet.dart';
import 'package:resonchat/ui/room/occupant_actions.dart';
import 'package:resonchat/ui/room/occupant_matrix.dart';
import 'package:resonchat/ui/room/room_config_page.dart';
import 'package:resonchat/ui/room/room_outcasts_page.dart';
import 'package:resonchat/ui/room/room_profile_viewmodel.dart';
import 'package:resonchat/ui/theme.dart';
import 'package:resonchat/xmpp/account_share_uri.dart';
import 'package:resonchat/xmpp/connection.dart';
import 'package:resonchat/xmpp/muc/muc.dart';
import 'package:resonchat/xmpp/roster/local_nickname.dart';

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
  String get _roomJid => resolveChatKey(widget.chatJid).jid;

  XmppService get _xmpp => resolveChatKey(widget.chatJid).session.xmpp;

  RoomProfileViewModel get _model =>
      ref.read(roomProfileViewModelProvider(widget.chatJid).notifier);

  void _popResult(RoomProfileResult result) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(context).pop(result);
    });
  }

  Future<void> _copyJid() async {
    await Clipboard.setData(ClipboardData(text: _roomJid));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(context.l10n.jidCopied)));
  }

  Future<void> _confirmDestroy() async {
    final caps = ref.read(roomProfileViewModelProvider(widget.chatJid)).caps;
    if (caps == null || !caps.canConfigureRoom) return;
    final l10n = context.l10n;
    final tg = context.appColors;
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
    final ui = ref.read(roomProfileViewModelProvider(widget.chatJid));
    final caps = ui.caps;
    if (caps == null || !caps.canConfigureRoom) return;
    final l10n = context.l10n;
    final controller = TextEditingController(text: ui.roomTitle ?? '');
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
    final ok = await _model.saveRoomName(trimmed);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? l10n.roomNameSaved : l10n.roomNameSaveFailed),
      ),
    );
  }

  Future<void> _pickRoomAvatar() async {
    final caps = ref.read(roomProfileViewModelProvider(widget.chatJid)).caps;
    if (caps == null || !caps.canConfigureRoom) return;
    final l10n = context.l10n;
    final picked = await FilePicker.pickFile(type: FileType.image);
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    if (bytes.isEmpty) return;
    final ok = await _model.publishAvatar(bytes);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? l10n.avatarPublished : l10n.avatarPublishFailed),
      ),
    );
  }

  Future<void> _editDescription() async {
    final ui = ref.read(roomProfileViewModelProvider(widget.chatJid));
    final caps = ui.caps;
    if (caps == null || !caps.canConfigureRoom) return;
    final l10n = context.l10n;
    final controller = TextEditingController(text: ui.description ?? '');
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
    final current = ref
        .read(roomProfileViewModelProvider(widget.chatJid))
        .description;
    if (trimmed == (current ?? '').trim()) return;
    final ok = await _model.saveDescription(trimmed);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok ? l10n.roomDescriptionSaved : l10n.roomDescriptionSaveFailed,
        ),
      ),
    );
  }

  Future<void> _editSubject(String? current) async {
    final caps = ref.read(roomProfileViewModelProvider(widget.chatJid)).caps;
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
    await _model.saveSubject(trimmed);
  }

  Future<void> _invite() async {
    final caps = ref.read(roomProfileViewModelProvider(widget.chatJid)).caps;
    if (caps == null || !caps.canInvite) return;
    final l10n = context.l10n;
    final ok = await showInviteMemberSheet(context, chatJid: widget.chatJid);
    if (!mounted || ok == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ok ? l10n.inviteSent : l10n.inviteFailed)),
    );
  }

  Future<void> _onOccupantTap(GroupChat room, Occupant occupant) async {
    final caps = ref.read(roomProfileViewModelProvider(widget.chatJid)).caps;
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
    final tg = context.appColors;
    final l10n = context.l10n;
    final ui = ref.watch(roomProfileViewModelProvider(widget.chatJid));
    final chatRow = ref.watch(chatProvider(widget.chatJid)).value;
    final roomAsync = ref.watch(roomStateProvider(widget.chatJid));
    final room = roomAsync.value;
    final caps = ui.caps;

    final storedTitle = chatRow?.title ?? '';
    final roomTitle = storedTitle.trim().isNotEmpty
        ? storedTitle
        : (ui.roomTitle ?? '');
    final shown = conversationDisplayName(
      storedLocalNickname: chatRow?.localNickname,
      title: roomTitle,
      jid: _roomJid,
      isRoom: true,
    );
    final heading = displayNameHeading(
      shown,
      conversationDisplayName(
        storedLocalNickname: null,
        title: roomTitle,
        jid: _roomJid,
        isRoom: true,
      ),
    );
    final desc = ui.description?.trim();
    final canEditDescription = caps?.canConfigureRoom ?? false;
    final subject = (ui.editedSubject ?? room?.subject)?.trim();
    final hasSubject = subject != null && subject.isNotEmpty;
    final canChangeSubject = caps?.canChangeSubject ?? false;

    final rosterGroups = groupOccupantsForRoster(room?.occupants ?? const []);

    return Scaffold(
      appBar: AppBar(title: Text(shown)),
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
                            ui.avatarPreview != null
                                ? ClipOval(
                                    child: Image.memory(
                                      ui.avatarPreview!,
                                      width: 88,
                                      height: 88,
                                      fit: BoxFit.cover,
                                    ),
                                  )
                                : ContactAvatar(
                                    jid: _roomJid,
                                    title: shown,
                                    radius: 44,
                                  ),
                            if ((caps?.canConfigureRoom ?? false) &&
                                !ui.avatarBusy)
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
                              heading,
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
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              _roomJid,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 14,
                                color: tg.textSecondary,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: l10n.copyJid,
                            visualDensity: VisualDensity.compact,
                            onPressed: () => unawaited(_copyJid()),
                            icon: Icon(
                              Icons.copy_outlined,
                              size: 18,
                              color: tg.textSecondary,
                            ),
                          ),
                        ],
                      ),
                      // Anyone-can-join rooms only: hide when disco
                      // muc_membersonly (ignore nonanonymous).
                      if (!_xmpp.isMembersOnly(_roomJid)) ...[
                        const SizedBox(height: 16),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          child: Text(
                            l10n.roomQrJoinHint(shown),
                            textAlign: TextAlign.center,
                            style: context.appText.helper,
                          ),
                        ),
                        const SizedBox(height: 12),
                        AccountQrCode(data: roomJoinUri(_roomJid)),
                      ],
                    ],
                  ),
                ),

                ConversationDisplayNameTile(
                  chatKey: widget.chatJid,
                  jid: _roomJid,
                  isRoom: true,
                  roomTitle: ui.roomTitle ?? '',
                ),

                _section(l10n.roomDescription),
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

                _section(l10n.subjectHint),
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
                ChatAutoTranslateSection(chatJid: widget.chatJid),
                ChatAppearanceSection(chatJid: widget.chatJid),

                _section(
                  ui.loadingCaps || room == null
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
                      style: context.appText.sectionHeader,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                    child: OccupantMatrix(
                      roomJid: _roomJid,
                      occupants: entry.value,
                      selfNick: room?.nick,
                      onTap: room == null
                          ? null
                          : (occupant) =>
                                unawaited(_onOccupantTap(room, occupant)),
                      onLongPress: room == null
                          ? null
                          : (occupant) =>
                                unawaited(_onOccupantTap(room, occupant)),
                    ),
                  ),
                ],

                _section(l10n.actions),
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
                if (caps?.canManageOutcasts ?? false)
                  ListTile(
                    leading: const Icon(Icons.person_off_outlined),
                    title: Text(l10n.roomOutcasts),
                    subtitle: Text(l10n.roomOutcastsSummary),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      Navigator.of(context).push<void>(
                        MaterialPageRoute<void>(
                          builder: (_) =>
                              RoomOutcastsPage(chatKey: widget.chatJid),
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

  Widget _section(String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        label,
        style: context.appText.sectionHeader,
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
}
