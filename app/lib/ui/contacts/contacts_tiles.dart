// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// List rows for the Contacts tab (idle roster, search hits, section chrome).

import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:resonchat/account/account_hub.dart';
import 'package:resonchat/l10n/l10n.dart';
import 'package:resonchat/state/providers.dart';
import 'package:resonchat/ui/account_list_chrome.dart';
import 'package:resonchat/ui/contact_avatar.dart';
import 'package:resonchat/ui/contacts/contacts_viewmodel.dart';
import 'package:resonchat/ui/contacts/groups_bookmarks_page.dart';
import 'package:resonchat/ui/dialog_cell.dart';
import 'package:resonchat/ui/home/open_chat.dart';
import 'package:resonchat/ui/room/channel_discovery_sheet.dart';
import 'package:resonchat/ui/room/create_group_sheet.dart';
import 'package:resonchat/ui/room/room_sheet.dart';
import 'package:resonchat/ui/theme.dart';
import 'package:resonchat/xmpp/roster/last_seen.dart';
import 'package:resonchat/xmpp/roster/local_nickname.dart';

TextStyle _detailStyle(Color color) {
  return TextStyle(color: color, fontSize: TgDimens.timeFontSize, height: 1.15);
}

/// Second line of a contact row. [leading] sits on the left (last seen).
/// When it is absent, [rest] starts at the left of the line.
Widget? _secondLine({
  String? leading,
  required Color leadingColor,
  required List<Widget> rest,
}) {
  if (leading == null && rest.isEmpty) return null;
  final children = <Widget>[
    if (leading != null)
      Flexible(
        child: Text(
          leading,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: _detailStyle(leadingColor),
        ),
      ),
    for (final part in rest) Flexible(child: part),
  ];
  return Row(
    children: [
      for (var i = 0; i < children.length; i++) ...[
        if (i > 0) const SizedBox(width: 8),
        children[i],
      ],
    ],
  );
}

class IdleContactsList extends StatelessWidget {
  const IdleContactsList({
    super.key,
    required this.contacts,
    required this.bookmarkCount,
    required this.onAddContact,
    this.filterAccountId,
  });

  final List<AccountContact> contacts;
  final int bookmarkCount;
  final VoidCallback onAddContact;

  /// When set, Groups opens with this account pre-selected.
  final String? filterAccountId;

  List<Widget> _prefix(BuildContext context) {
    final l10n = context.l10n;
    return [
      ContactActionTile(
        icon: Icons.person_add_outlined,
        title: l10n.addContact,
        onTap: onAddContact,
      ),
      ContactActionTile(
        icon: Icons.login,
        title: l10n.joinGroup,
        onTap: () => showJoinRoomSheet(context),
      ),
      ContactActionTile(
        icon: Icons.travel_explore_outlined,
        title: l10n.discoverChannels,
        onTap: () => showChannelDiscoverySheet(context),
      ),
      ContactActionTile(
        icon: Icons.group_add_outlined,
        title: l10n.createPrivateGroup,
        onTap: () => showCreatePrivateGroupSheet(context),
      ),
      ContactActionTile(
        icon: Icons.campaign_outlined,
        title: l10n.createPublicChannel,
        onTap: () => showCreatePublicChannelSheet(context),
      ),
      GroupsBookmarkEntry(
        count: bookmarkCount,
        filterAccountId: filterAccountId,
      ),
      SearchSectionHeader(title: l10n.searchSectionContacts),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tg = context.tg;
    final rows = <Widget>[
      ..._prefix(context),
      if (contacts.isEmpty && bookmarkCount == 0)
        Padding(
          padding: const EdgeInsets.all(32),
          child: Center(
            child: Text(
              l10n.noContactsYet,
              style: TextStyle(color: tg.textSecondary),
            ),
          ),
        )
      else
        ...contacts.map(
          (entry) => ContactRosterTile(
            entry: entry,
            showAccountColor: filterAccountId == null,
          ),
        ),
    ];
    return ListView.separated(
      itemCount: rows.length,
      separatorBuilder: (context, i) {
        if (rows[i] is SearchSectionHeader ||
            rows[i + 1] is SearchSectionHeader) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.only(left: 82),
          child: Divider(height: 0.5, color: tg.separator),
        );
      },
      itemBuilder: (context, i) => rows[i],
    );
  }
}

/// One shortcut row, drawn like a contact: round icon, then the title.
class ContactActionTile extends StatelessWidget {
  const ContactActionTile({
    super.key,
    required this.icon,
    required this.title,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tg = context.tg;
    return DialogCell(
      onTap: onTap,
      leading: _actionAvatar(icon, tg.accent),
      title: title,
    );
  }
}

Widget _actionAvatar(IconData icon, Color accent) {
  return CircleAvatar(
    radius: TgDimens.avatarChats / 2,
    backgroundColor: accent.withValues(alpha: 0.18),
    child: Icon(icon, color: accent),
  );
}

class SearchSectionHeader extends StatelessWidget {
  const SearchSectionHeader({super.key, required this.title, this.count});

  final String title;
  final int? count;

  @override
  Widget build(BuildContext context) {
    final tg = context.tg;
    final count = this.count;
    final label = count == null ? title : '$title · $count';
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        TgDimens.chatsHorizontalPadding,
        12,
        TgDimens.chatsHorizontalPadding,
        4,
      ),
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

class SearchExpandToggle extends StatelessWidget {
  const SearchExpandToggle({
    super.key,
    required this.expanded,
    required this.hiddenCount,
    required this.onTap,
  });

  final bool expanded;
  final int hiddenCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tg = context.tg;
    final label = expanded
        ? l10n.searchShowLess
        : l10n.searchShowMore(hiddenCount);
    return ListTile(
      dense: true,
      title: Text(label, style: TextStyle(color: tg.accent, fontSize: 14)),
      trailing: Icon(
        expanded ? Icons.expand_less : Icons.expand_more,
        color: tg.accent,
      ),
      onTap: onTap,
    );
  }
}

class ContactRosterTile extends ConsumerWidget {
  const ContactRosterTile({
    super.key,
    required this.entry,
    this.showAccountColor = true,
  });

  final AccountContact entry;

  /// Account halo and via label. Off when the list is filtered to one account.
  final bool showAccountColor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tg = context.tg;
    final multi =
        showAccountColor && ref.watch(accountHubProvider).accounts.length > 1;
    final accent = entry.accent;
    final presence = ref.watch(contactPresenceProvider(entry.ref.key)).value;
    final seen = lastSeenLine(context.l10n, presence?.idleSince);
    final chat = ref.watch(chatProvider(entry.ref.key)).value;
    final title = conversationDisplayName(
      storedLocalNickname: chat?.localNickname,
      title: entry.entry.name,
      jid: entry.entry.jid,
      isRoom: false,
    );
    final jid = title == entry.entry.jid ? null : entry.entry.jid;
    return DialogCell(
      onTap: () async {
        final key = await ref
            .read(contactsViewModelProvider.notifier)
            .openContact(entry);
        if (!context.mounted || key == null) return;
        openChat(context, key);
      },
      leading: accountAvatarRing(
        show: multi,
        accent: accent,
        child: ContactAvatar(
          jid: entry.entry.jid,
          title: title,
          showPresence: true,
          presence: presence?.show,
        ),
      ),
      title: title,
      subtitle: _secondLine(
        leading: seen,
        leadingColor: tg.textSecondary,
        rest: [
          if (multi) accountViaText(entry.account.bareJid, accent),
          if (jid != null)
            Text(
              jid,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: _detailStyle(tg.textSecondary),
            ),
        ],
      ),
    );
  }
}

class GroupBookmarkTile extends ConsumerWidget {
  const GroupBookmarkTile({
    super.key,
    required this.row,
    required this.onTap,
    this.showAccountColor = true,
  });

  final AccountBookmark row;
  final VoidCallback onTap;

  /// Account halo and via label. Off when the list is filtered to one account.
  final bool showAccountColor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tg = context.tg;
    final multi =
        showAccountColor && ref.watch(accountHubProvider).accounts.length > 1;
    final accent = row.accent;
    final b = row.bookmark;
    final chat = ref.watch(chatProvider(row.ref.key)).value;
    final title = conversationDisplayName(
      storedLocalNickname: chat?.localNickname,
      title: b.displayName,
      jid: b.jid,
      isRoom: true,
    );
    return DialogCell(
      onTap: onTap,
      leading: accountAvatarRing(
        show: multi,
        accent: accent,
        child: ContactAvatar(jid: b.jid, title: title),
      ),
      title: title,
      subtitle: _secondLine(
        leadingColor: tg.textSecondary,
        rest: [
          if (multi) accountViaText(row.account.bareJid, accent),
          Text(
            b.jid,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: _detailStyle(tg.textSecondary),
          ),
        ],
      ),
    );
  }
}

class AddJidTile extends StatelessWidget {
  const AddJidTile({super.key, required this.jid, required this.onTap});

  final String jid;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tg = context.tg;
    return DialogCell(
      onTap: onTap,
      leading: _actionAvatar(Icons.person_add, tg.accent),
      title: l10n.addContact,
      subtitle: Text(
        jid,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: _detailStyle(tg.textSecondary),
      ),
      trailing: Icon(Icons.arrow_forward, color: tg.accent, size: 20),
    );
  }
}

class AddGroupTile extends StatelessWidget {
  const AddGroupTile({super.key, required this.jid, required this.onTap});

  final String jid;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tg = context.tg;
    return DialogCell(
      onTap: onTap,
      leading: _actionAvatar(Icons.group_add_outlined, tg.accent),
      title: l10n.joinGroup,
      subtitle: Text(
        jid,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: _detailStyle(tg.textSecondary),
      ),
      trailing: Icon(Icons.arrow_forward, color: tg.accent, size: 20),
    );
  }
}

class GroupsBookmarkEntry extends StatelessWidget {
  const GroupsBookmarkEntry({
    super.key,
    required this.count,
    this.filterAccountId,
  });

  final int count;
  final String? filterAccountId;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tg = context.tg;
    return DialogCell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) =>
              GroupsBookmarksPage(initialAccountId: filterAccountId),
        ),
      ),
      leading: _actionAvatar(Icons.groups, tg.accent),
      title: l10n.groupBookmarks,
      subtitle: Text(
        count == 0 ? l10n.groupBookmarksEmpty : l10n.groupBookmarksCount(count),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: _detailStyle(tg.textSecondary),
      ),
      trailing: Icon(Icons.chevron_right, color: tg.textSecondary),
    );
  }
}
