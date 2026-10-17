// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// List rows for the Contacts tab (idle roster, search hits, section chrome).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../account/account_hub.dart';
import '../../l10n/l10n.dart';
import '../../state/providers.dart';
import '../../xmpp/last_seen.dart';
import '../account_list_chrome.dart';
import '../contact_avatar.dart';
import '../home/open_chat.dart';
import '../room/channel_discovery_sheet.dart';
import '../room/create_group_sheet.dart';
import '../room/room_sheet.dart';
import '../theme.dart';
import 'contacts_viewmodel.dart';
import 'groups_bookmarks_page.dart';

/// Idle (no search): Groups entry + full roster.
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
    ];
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tg = context.tg;
    final prefix = _prefix(context);
    if (contacts.isEmpty && bookmarkCount == 0) {
      return ListView(
        children: [
          ...prefix,
          Padding(
            padding: const EdgeInsets.all(32),
            child: Center(
              child: Text(
                l10n.noContactsYet,
                style: TextStyle(color: tg.textSecondary),
              ),
            ),
          ),
        ],
      );
    }
    return ListView.separated(
      itemCount: contacts.length + prefix.length,
      separatorBuilder: (_, _) => Padding(
        padding: const EdgeInsets.only(left: 82),
        child: Divider(height: 0.5, color: tg.separator),
      ),
      itemBuilder: (context, i) {
        if (i < prefix.length) return prefix[i];
        return ContactRosterTile(entry: contacts[i - prefix.length]);
      },
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
    return ListTile(
      leading: CircleAvatar(
        radius: 22,
        backgroundColor: tg.accent.withValues(alpha: 0.18),
        child: Icon(icon, color: tg.accent),
      ),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: onTap,
    );
  }
}

class SearchSectionHeader extends StatelessWidget {
  const SearchSectionHeader({
    super.key,
    required this.title,
    required this.count,
  });

  final String title;
  final int count;

  @override
  Widget build(BuildContext context) {
    final tg = context.tg;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        TgDimens.chatsHorizontalPadding,
        12,
        TgDimens.chatsHorizontalPadding,
        4,
      ),
      child: Text(
        '$title · $count',
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
  const ContactRosterTile({super.key, required this.entry});

  final AccountContact entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tg = context.tg;
    final multi = ref.watch(accountHubProvider).accounts.length > 1;
    final accent = entry.accent;
    final presence = ref.watch(contactPresenceProvider(entry.ref.key)).value;
    final seen = lastSeenLine(context.l10n, presence?.idleSince);
    final jidLine = entry.displayName == entry.entry.jid
        ? null
        : Text(
            entry.entry.jid,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: tg.textSecondary,
              fontSize: TgDimens.timeFontSize,
            ),
          );
    return Container(
      decoration: accountStripeDecoration(accent, show: multi),
      child: ListTile(
        leading: accountAvatarRing(
          show: multi,
          accent: accent,
          child: ContactAvatar(
            jid: entry.entry.jid,
            title: entry.displayName,
            radius: 22,
            showPresence: true,
            presence: presence?.show,
          ),
        ),
        title: Text(
          entry.displayName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: (!multi && jidLine == null && seen == null)
            ? null
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (multi) accountViaText(entry.account.bareJid, accent),
                  ?jidLine,
                  if (seen != null)
                    Text(
                      seen,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: tg.textSecondary,
                        fontSize: TgDimens.timeFontSize,
                      ),
                    ),
                ],
              ),
        onTap: () async {
          final key = await ref
              .read(contactsViewModelProvider.notifier)
              .openContact(entry);
          if (!context.mounted || key == null) return;
          openChat(context, key);
        },
      ),
    );
  }
}

class GroupBookmarkTile extends ConsumerWidget {
  const GroupBookmarkTile({super.key, required this.row, required this.onTap});

  final AccountBookmark row;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tg = context.tg;
    final multi = ref.watch(accountHubProvider).accounts.length > 1;
    final accent = row.accent;
    final b = row.bookmark;
    return Container(
      decoration: accountStripeDecoration(accent, show: multi),
      child: ListTile(
        leading: accountAvatarRing(
          show: multi,
          accent: accent,
          child: ContactAvatar(jid: b.jid, title: b.displayName, radius: 22),
        ),
        title: Text(
          b.displayName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (multi) accountViaText(row.account.bareJid, accent),
            Text(
              b.jid,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: tg.textSecondary,
                fontSize: TgDimens.timeFontSize,
              ),
            ),
          ],
        ),
        onTap: onTap,
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
    return ListTile(
      leading: CircleAvatar(
        radius: 22,
        backgroundColor: tg.accent.withValues(alpha: 0.18),
        child: Icon(Icons.person_add, color: tg.accent),
      ),
      title: Text(l10n.addContact),
      subtitle: Text(
        jid,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: tg.textSecondary,
          fontSize: TgDimens.timeFontSize,
        ),
      ),
      trailing: Icon(Icons.arrow_forward, color: tg.accent, size: 20),
      onTap: onTap,
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
    return ListTile(
      leading: CircleAvatar(
        radius: 22,
        backgroundColor: tg.accent.withValues(alpha: 0.18),
        child: Icon(Icons.group_add_outlined, color: tg.accent),
      ),
      title: Text(l10n.joinGroup),
      subtitle: Text(
        jid,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: tg.textSecondary,
          fontSize: TgDimens.timeFontSize,
        ),
      ),
      trailing: Icon(Icons.arrow_forward, color: tg.accent, size: 20),
      onTap: onTap,
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
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: tg.accent.withValues(alpha: 0.18),
        child: Icon(Icons.groups, color: tg.accent),
      ),
      title: Text(l10n.groupBookmarks),
      subtitle: Text(
        count == 0 ? l10n.groupBookmarksEmpty : l10n.groupBookmarksCount(count),
        style: TextStyle(
          color: tg.textSecondary,
          fontSize: TgDimens.timeFontSize,
        ),
      ),
      trailing: Icon(Icons.chevron_right, color: tg.textSecondary),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) =>
              GroupsBookmarksPage(initialAccountId: filterAccountId),
        ),
      ),
    );
  }
}
