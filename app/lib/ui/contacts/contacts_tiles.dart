// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// List rows for the Contacts tab (idle roster, search hits, section chrome).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../account/account_hub.dart';
import '../../l10n/l10n.dart';
import '../../state/providers.dart';
import '../contact_avatar.dart';
import '../home/open_chat.dart';
import '../theme.dart';
import 'contacts_viewmodel.dart';
import 'groups_bookmarks_page.dart';

/// Idle (no search): Groups entry + full roster.
class IdleContactsList extends StatelessWidget {
  const IdleContactsList({
    super.key,
    required this.contacts,
    required this.bookmarkCount,
  });

  final List<AccountContact> contacts;
  final int bookmarkCount;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tg = context.tg;
    if (contacts.isEmpty && bookmarkCount == 0) {
      return ListView(
        children: [
          GroupsBookmarkEntry(count: bookmarkCount),
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
      itemCount: contacts.length + 1,
      separatorBuilder: (_, _) => Padding(
        padding: const EdgeInsets.only(left: 82),
        child: Divider(height: 0.5, color: tg.separator),
      ),
      itemBuilder: (context, i) {
        if (i == 0) return GroupsBookmarkEntry(count: bookmarkCount);
        return ContactRosterTile(entry: contacts[i - 1]);
      },
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
    final presence = ref
        .watch(contactPresenceProvider(entry.ref.key))
        .value
        ?.show;
    return ListTile(
      leading: ContactAvatar(
        jid: entry.entry.jid,
        title: entry.displayName,
        radius: 22,
        showPresence: true,
        presence: presence,
      ),
      title: Text(
        entry.displayName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: entry.displayName == entry.entry.jid
          ? null
          : Text(
              entry.entry.jid,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: tg.textSecondary,
                fontSize: TgDimens.timeFontSize,
              ),
            ),
      onTap: () async {
        final key = await ref
            .read(contactsViewModelProvider.notifier)
            .openContact(entry);
        if (!context.mounted || key == null) return;
        openChat(context, key);
      },
    );
  }
}

class GroupBookmarkTile extends StatelessWidget {
  const GroupBookmarkTile({super.key, required this.row, required this.onTap});

  final AccountBookmark row;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tg = context.tg;
    final b = row.bookmark;
    return ListTile(
      leading: ContactAvatar(jid: b.jid, title: b.displayName, radius: 22),
      title: Text(b.displayName, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        b.jid,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: tg.textSecondary,
          fontSize: TgDimens.timeFontSize,
        ),
      ),
      onTap: onTap,
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

class GroupsBookmarkEntry extends StatelessWidget {
  const GroupsBookmarkEntry({super.key, required this.count});

  final int count;

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
        MaterialPageRoute<void>(builder: (_) => const GroupsBookmarksPage()),
      ),
    );
  }
}
