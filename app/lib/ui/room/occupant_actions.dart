// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Shared Gajim-style occupant action sheet (room profile + in-chat avatar).
//
// Online vs offline follows Gajim `get_groupchat_*_menu`:
// - Moderation (kick / voice) needs a live occupant (`is_available`).
// - Administration (affiliation / ban) needs a real bare JID (works offline).
// - In-room PM needs a live occupant; direct 1:1 needs a visible real JID.

import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:resonchat/account/resolve.dart';
import 'package:resonchat/l10n/l10n.dart';
import 'package:resonchat/state/providers.dart';
import 'package:resonchat/ui/chats/chats_viewmodel.dart';
import 'package:resonchat/ui/theme.dart';
import 'package:resonchat/xmpp/connection.dart';
import 'package:resonchat/xmpp/muc/muc.dart';

enum OccupantSheetAction {
  privateChat,
  mucPm,
  addContact,
  kick,
  ban,
  grantVoice,
  revokeVoice,
  makeOwner,
  makeAdmin,
  makeMember,
  revokeMember,
}

/// Shows the member menu. Returns the chosen action, or null if dismissed /
/// nothing was available. Callers run navigation for [privateChat] / [mucPm];
/// use [applyOccupantSheetAction] for the rest.
Future<OccupantSheetAction?> showOccupantActionsSheet({
  required BuildContext context,
  required WidgetRef ref,
  required String chatKey,
  required GroupChat room,
  required Occupant occupant,
  required RoomSelfCapabilities caps,
}) async {
  if (occupant.nick == room.nick) return null;
  final l10n = context.l10n;
  final tg = context.tg;

  // Always re-resolve against the live roster so a chat-avatar long-press on an
  // old message does not treat a now-offline member as still kickable.
  final live = occupantByNick(room, occupant.nick) ?? occupant;
  final online = live.isOnline;
  final realJid = live.realJid;
  final hasJid = realJid != null && realJid.isNotEmpty;

  // Gajim Direct Message: real JID when visible; muc PM only while available.
  final canPrivateChat = hasJid;
  final canMucPm = online && caps.allowPm && live.nick.isNotEmpty;

  final accountId = resolveChatKey(chatKey).session.account.id;
  final roster = ref.read(rosterProvider).value ?? const [];
  final onRoster =
      hasJid &&
      roster.any((c) => c.account.id == accountId && c.entry.jid == realJid);
  final canAddContact = hasJid && !onRoster;

  // Gajim `get_groupchat_mod_menu`: empty / "Not Available" when offline.
  final selfIsModerator = roleRank(caps.role) >= roleRank('moderator');
  final canModerate = online && caps.canChangeRole(live);
  final canKick = canModerate;
  final canGrantVoice = canModerate && live.role == 'visitor';
  final canRevokeVoice =
      canModerate && (live.role == 'participant' || live.role == 'moderator');
  final hasModeration = canKick || canGrantVoice || canRevokeVoice;
  final showModSection = selfIsModerator;

  // Gajim `get_groupchat_admin_menu`: needs real_jid (offline OK).
  final selfIsAdmin =
      caps.affiliation == 'owner' || caps.affiliation == 'admin';
  final canMakeOwner = hasJid && caps.canChangeAffiliation(live, 'owner');
  final canMakeAdmin = hasJid && caps.canChangeAffiliation(live, 'admin');
  final canMakeMember = hasJid && caps.canChangeAffiliation(live, 'member');
  final canRevokeMember = hasJid && caps.canChangeAffiliation(live, 'none');
  final canBan = hasJid && caps.canChangeAffiliation(live, 'outcast');
  final hasAdmin =
      canMakeOwner ||
      canMakeAdmin ||
      canMakeMember ||
      canRevokeMember ||
      canBan;
  final showAdminSection = selfIsAdmin;

  final hasGeneral = canPrivateChat || canMucPm || canAddContact;
  // Privileged users still open the sheet to see Gajim-style "Not available"
  // under Moderation / Administration when the target is offline / has no JID.
  if (!hasGeneral && !showModSection && !showAdminSection) {
    return null;
  }

  return showModalBottomSheet<OccupantSheetAction>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(live.nick),
              subtitle: hasJid
                  ? Text(realJid, style: TextStyle(color: tg.textSecondary))
                  : null,
            ),
            if (canPrivateChat)
              ListTile(
                leading: const Icon(Icons.chat_bubble_outline),
                title: Text(l10n.privateChat),
                onTap: () => Navigator.pop(
                  sheetContext,
                  OccupantSheetAction.privateChat,
                ),
              ),
            if (canMucPm)
              ListTile(
                leading: const Icon(Icons.lock_outline),
                title: Text(l10n.privateMessageInRoom),
                onTap: () =>
                    Navigator.pop(sheetContext, OccupantSheetAction.mucPm),
              ),
            if (canAddContact)
              ListTile(
                leading: const Icon(Icons.person_add_outlined),
                title: Text(l10n.addContact),
                onTap: () =>
                    Navigator.pop(sheetContext, OccupantSheetAction.addContact),
              ),
            if (showModSection) ...[
              _sheetSection(tg, l10n.roomModeration),
              if (!hasModeration)
                ListTile(
                  enabled: false,
                  title: Text(
                    l10n.roomActionUnavailable,
                    style: TextStyle(color: tg.textSecondary),
                  ),
                )
              else ...[
                if (canKick)
                  ListTile(
                    leading: Icon(
                      Icons.person_remove_outlined,
                      color: tg.danger,
                    ),
                    title: Text(
                      l10n.kickFromRoom,
                      style: TextStyle(color: tg.danger),
                    ),
                    onTap: () =>
                        Navigator.pop(sheetContext, OccupantSheetAction.kick),
                  ),
                if (canGrantVoice)
                  ListTile(
                    leading: const Icon(Icons.record_voice_over_outlined),
                    title: Text(l10n.grantVoice),
                    onTap: () => Navigator.pop(
                      sheetContext,
                      OccupantSheetAction.grantVoice,
                    ),
                  ),
                if (canRevokeVoice)
                  ListTile(
                    leading: const Icon(Icons.voice_over_off_outlined),
                    title: Text(l10n.revokeVoice),
                    onTap: () => Navigator.pop(
                      sheetContext,
                      OccupantSheetAction.revokeVoice,
                    ),
                  ),
              ],
            ],
            if (showAdminSection) ...[
              _sheetSection(tg, l10n.roomAdministration),
              if (!hasAdmin)
                ListTile(
                  enabled: false,
                  title: Text(
                    l10n.roomActionUnavailable,
                    style: TextStyle(color: tg.textSecondary),
                  ),
                )
              else ...[
                if (canMakeOwner)
                  ListTile(
                    leading: const Icon(Icons.workspace_premium_outlined),
                    title: Text(l10n.makeOwner),
                    onTap: () => Navigator.pop(
                      sheetContext,
                      OccupantSheetAction.makeOwner,
                    ),
                  ),
                if (canMakeAdmin)
                  ListTile(
                    leading: const Icon(Icons.admin_panel_settings_outlined),
                    title: Text(l10n.makeAdmin),
                    onTap: () => Navigator.pop(
                      sheetContext,
                      OccupantSheetAction.makeAdmin,
                    ),
                  ),
                if (canMakeMember)
                  ListTile(
                    leading: const Icon(Icons.badge_outlined),
                    title: Text(l10n.makeMember),
                    onTap: () => Navigator.pop(
                      sheetContext,
                      OccupantSheetAction.makeMember,
                    ),
                  ),
                if (canRevokeMember)
                  ListTile(
                    leading: const Icon(Icons.badge_outlined),
                    title: Text(l10n.revokeMember),
                    onTap: () => Navigator.pop(
                      sheetContext,
                      OccupantSheetAction.revokeMember,
                    ),
                  ),
                if (canBan)
                  ListTile(
                    leading: Icon(Icons.block, color: tg.danger),
                    title: Text(
                      l10n.banFromRoom,
                      style: TextStyle(color: tg.danger),
                    ),
                    onTap: () =>
                        Navigator.pop(sheetContext, OccupantSheetAction.ban),
                  ),
              ],
            ],
            const SizedBox(height: 8),
          ],
        ),
      ),
    ),
  );
}

Widget _sheetSection(TgColors tg, String label) {
  return Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
    child: Align(
      alignment: Alignment.centerLeft,
      child: Text(
        label,
        style: TextStyle(
          color: tg.textSecondary,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
  );
}

Future<bool> _confirmDanger(
  BuildContext context, {
  required String title,
  required String body,
  required String actionLabel,
}) async {
  await WidgetsBinding.instance.endOfFrame;
  if (!context.mounted) return false;
  final tg = context.tg;
  final l10n = context.l10n;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: Text(l10n.cancel),
        ),
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: Text(actionLabel, style: TextStyle(color: tg.danger)),
        ),
      ],
    ),
  );
  return confirmed == true;
}

/// Runs non-navigation actions from [showOccupantActionsSheet].
///
/// Returns `true` when the room roster should be refreshed. [privateChat] and
/// [mucPm] are no-ops here — the caller handles those.
Future<bool> applyOccupantSheetAction({
  required BuildContext context,
  required WidgetRef ref,
  required String chatKey,
  required String roomJid,
  required Occupant occupant,
  required XmppService xmpp,
  required OccupantSheetAction action,
}) async {
  final l10n = context.l10n;
  // Prefer live roster state at apply time (may have changed since the sheet).
  final room = ref.read(roomStateProvider(chatKey)).value;
  final live = room == null
      ? occupant
      : (occupantByNick(room, occupant.nick) ?? occupant);
  final realJid = live.realJid;

  switch (action) {
    case OccupantSheetAction.privateChat:
    case OccupantSheetAction.mucPm:
      return false;
    case OccupantSheetAction.addContact:
      if (realJid == null || realJid.isEmpty) return false;
      final accountId = resolveChatKey(chatKey).session.account.id;
      final result = await ref
          .read(chatsViewModelProvider.notifier)
          .openChatByJid(realJid, accountId: accountId);
      if (!context.mounted) return false;
      final ok = result.contactAdded == true || result.chatKey != null;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ok ? l10n.contactAdded : l10n.contactAddFailed)),
      );
      return false;
    case OccupantSheetAction.kick:
      if (!live.isOnline) return false;
      final confirmed = await _confirmDanger(
        context,
        title: l10n.kickFromRoom,
        body: l10n.kickFromRoomConfirm(live.nick),
        actionLabel: l10n.kickFromRoom,
      );
      if (!confirmed || !context.mounted) return false;
      final ok = await xmpp.kickOccupant(roomJid, live);
      if (!context.mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ok ? l10n.kickSucceeded : l10n.kickFailed)),
      );
      return ok;
    case OccupantSheetAction.ban:
      if (realJid == null || realJid.isEmpty) return false;
      final confirmed = await _confirmDanger(
        context,
        title: l10n.banFromRoom,
        body: l10n.banFromRoomConfirm(live.nick),
        actionLabel: l10n.banFromRoom,
      );
      if (!confirmed || !context.mounted) return false;
      final ok = await xmpp.banOccupant(roomJid, live);
      if (!context.mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ok ? l10n.banSucceeded : l10n.banFailed)),
      );
      return ok;
    case OccupantSheetAction.grantVoice:
    case OccupantSheetAction.revokeVoice:
      if (!live.isOnline) return false;
      final grant = action == OccupantSheetAction.grantVoice;
      final ok = await xmpp.setOccupantVoice(roomJid, live, grant: grant);
      if (!context.mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ok ? l10n.voiceChanged : l10n.voiceChangeFailed),
        ),
      );
      return ok;
    case OccupantSheetAction.makeOwner:
    case OccupantSheetAction.makeAdmin:
    case OccupantSheetAction.makeMember:
    case OccupantSheetAction.revokeMember:
      if (realJid == null || realJid.isEmpty) return false;
      final affiliation = switch (action) {
        OccupantSheetAction.makeOwner => 'owner',
        OccupantSheetAction.makeAdmin => 'admin',
        OccupantSheetAction.makeMember => 'member',
        _ => 'none',
      };
      final ok = await xmpp.setOccupantAffiliation(roomJid, live, affiliation);
      if (!context.mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ok ? l10n.affiliationChanged : l10n.affiliationChangeFailed,
          ),
        ),
      );
      return ok;
  }
}

/// Full flow: sheet + apply. Returns nav intent for private chat / muc PM.
Future<({String? privateChatJid, String? mucPmNick})?> runOccupantActions({
  required BuildContext context,
  required WidgetRef ref,
  required String chatKey,
  required GroupChat room,
  required Occupant occupant,
  required RoomSelfCapabilities caps,
  required XmppService xmpp,
}) async {
  final live = occupantByNick(room, occupant.nick) ?? occupant;
  final action = await showOccupantActionsSheet(
    context: context,
    ref: ref,
    chatKey: chatKey,
    room: room,
    occupant: live,
    caps: caps,
  );
  if (action == null || !context.mounted) return null;

  // Re-read after the sheet in case presence changed while it was open.
  final latestRoom = ref.read(roomStateProvider(chatKey)).value ?? room;
  final latest = occupantByNick(latestRoom, live.nick) ?? live;

  switch (action) {
    case OccupantSheetAction.privateChat:
      final jid = latest.realJid;
      if (jid == null || jid.isEmpty) return null;
      return (privateChatJid: jid, mucPmNick: null);
    case OccupantSheetAction.mucPm:
      if (!latest.isOnline) return null;
      return (privateChatJid: null, mucPmNick: latest.nick);
    default:
      final refreshed = await applyOccupantSheetAction(
        context: context,
        ref: ref,
        chatKey: chatKey,
        roomJid: room.roomJid,
        occupant: latest,
        xmpp: xmpp,
        action: action,
      );
      if (refreshed) {
        ref.invalidate(roomStateProvider(chatKey));
      }
      return null;
  }
}
