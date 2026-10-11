// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Contacts tab: roster list + add-contact search. Group bookmarks are a
// single top entry that opens a dedicated page — never mixed into the roster.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/providers.dart';
import '../chats/chats_viewmodel.dart';
import '../contact_avatar.dart';
import '../home/open_chat.dart';
import '../pending/pending_requests_page.dart';
import '../room/create_group_sheet.dart';
import '../theme.dart';
import 'groups_bookmarks_page.dart';

class ContactsPage extends ConsumerStatefulWidget {
  const ContactsPage({super.key});

  @override
  ConsumerState<ContactsPage> createState() => _ContactsPageState();
}

class _ContactsPageState extends ConsumerState<ContactsPage> {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _addContact() async {
    final raw = _query.text.trim();
    if (raw.isEmpty) return;
    final result = await ref
        .read(chatsViewModelProvider.notifier)
        .openChatByJid(raw);
    if (!mounted) return;
    final l10n = context.l10n;
    if (result.invalidJid) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.invalidJid)));
      return;
    }
    if (result.chatKey == null) return;
    _query.clear();
    final added = result.contactAdded;
    if (added != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            added ? l10n.contactRequestSent : l10n.contactAddFailed,
          ),
        ),
      );
    }
    openChat(context, result.chatKey!);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tg = context.tg;
    final roster = ref.watch(rosterProvider);
    final bookmarks = ref.watch(bookmarksProvider);
    final bookmarkCount = bookmarks.asData?.value.length ?? 0;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.tabContacts),
        actions: [
          IconButton(
            icon: const Icon(Icons.person_add_alt),
            tooltip: l10n.pendingRequests,
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const PendingRequestsPage(),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.group_add_outlined),
            tooltip: l10n.joinGroup,
            onPressed: () => showGroupActionsSheet(context),
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: l10n.settings,
            onPressed: () => Navigator.of(context).pushNamed('/settings'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              TgDimens.chatsHorizontalPadding,
              8,
              TgDimens.chatsHorizontalPadding,
              8,
            ),
            child: TextField(
              controller: _query,
              onSubmitted: (_) => _addContact(),
              style: TextStyle(fontSize: TgDimens.chatSubtitleFontSize),
              decoration: InputDecoration(
                isDense: true,
                hintText: l10n.addContactHint,
                hintStyle: TextStyle(color: tg.textSecondary),
                prefixIcon: Icon(
                  Icons.person_add,
                  size: 18,
                  color: tg.textSecondary,
                ),
                suffixIcon: IconButton(
                  icon: Icon(Icons.arrow_forward, color: tg.accent, size: 20),
                  tooltip: l10n.addContact,
                  onPressed: _addContact,
                ),
                filled: true,
                fillColor: tg.separator.withValues(alpha: 0.35),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(18),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(18),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          Expanded(
            child: roster.when(
              data: (list) {
                // +1 for the Groups bookmark entry at the top.
                final count = list.length + 1;
                if (list.isEmpty && bookmarkCount == 0) {
                  return ListView(
                    children: [
                      _GroupsEntry(count: bookmarkCount),
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
                  itemCount: count,
                  separatorBuilder: (_, _) => Padding(
                    padding: const EdgeInsets.only(left: 82),
                    child: Divider(height: 0.5, color: tg.separator),
                  ),
                  itemBuilder: (context, i) {
                    if (i == 0) {
                      return _GroupsEntry(count: bookmarkCount);
                    }
                    final entry = list[i - 1];
                    return ListTile(
                      leading: ContactAvatar(
                        jid: entry.entry.jid,
                        title: entry.displayName,
                        radius: 22,
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
                      onTap: () => openChat(context, entry.ref.key),
                    );
                  },
                );
              },
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('$e')),
            ),
          ),
        ],
      ),
    );
  }
}

class _GroupsEntry extends StatelessWidget {
  const _GroupsEntry({required this.count});

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
