// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Contacts tab shell: search field + idle roster or grouped search results.
// Matching, tiles, and side effects live in sibling files.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../account/account_hub.dart';
import '../../l10n/l10n.dart';
import '../../state/providers.dart';
import '../home/open_chat.dart';
import '../pending/pending_requests_page.dart';
import '../room/create_group_sheet.dart';
import '../theme.dart';
import 'contacts_match.dart';
import 'contacts_tiles.dart';
import 'contacts_viewmodel.dart';

class ContactsPage extends ConsumerStatefulWidget {
  const ContactsPage({super.key});

  @override
  ConsumerState<ContactsPage> createState() => _ContactsPageState();
}

class _ContactsPageState extends ConsumerState<ContactsPage> {
  static const _previewLimit = 3;

  final _query = TextEditingController();
  String _needle = '';
  bool _contactsExpanded = false;
  bool _groupsExpanded = false;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    setState(() {
      _needle = value;
      _contactsExpanded = false;
      _groupsExpanded = false;
    });
  }

  void _clearQuery() {
    _query.clear();
    setState(() {
      _needle = '';
      _contactsExpanded = false;
      _groupsExpanded = false;
    });
  }

  Future<void> _addContact(String raw) async {
    final result = await ref
        .read(contactsViewModelProvider.notifier)
        .addContactByJid(raw);
    if (!mounted) return;
    final l10n = context.l10n;
    if (result.invalidJid) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.invalidJid)));
      return;
    }
    if (result.chatKey == null) return;
    _clearQuery();
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

  Future<void> _openBookmark(AccountBookmark row) async {
    final key = await ref
        .read(contactsViewModelProvider.notifier)
        .openBookmark(row);
    if (!mounted || key == null) return;
    openChat(context, key);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tg = context.tg;
    final roster = ref.watch(rosterProvider);
    final bookmarks = ref.watch(bookmarksProvider);
    final bookmarkList = bookmarks.asData?.value ?? const <AccountBookmark>[];
    final bookmarkCount = bookmarkList.length;
    final searching = _needle.trim().isNotEmpty;

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
              onChanged: _onQueryChanged,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) {
                final jid = completeJidCandidate(_needle);
                if (jid != null) unawaited(_addContact(jid));
              },
              style: TextStyle(fontSize: TgDimens.chatSubtitleFontSize),
              decoration: InputDecoration(
                isDense: true,
                hintText: l10n.searchContactsHint,
                hintStyle: TextStyle(color: tg.textSecondary),
                prefixIcon: Icon(
                  Icons.search,
                  size: 18,
                  color: tg.textSecondary,
                ),
                suffixIcon: searching
                    ? IconButton(
                        icon: Icon(
                          Icons.clear,
                          color: tg.textSecondary,
                          size: 20,
                        ),
                        tooltip: l10n.cancel,
                        onPressed: _clearQuery,
                      )
                    : null,
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
                if (!searching) {
                  return IdleContactsList(
                    contacts: list,
                    bookmarkCount: bookmarkCount,
                  );
                }
                return _SearchResults(
                  contacts: list,
                  bookmarks: bookmarkList,
                  needle: _needle,
                  contactsExpanded: _contactsExpanded,
                  groupsExpanded: _groupsExpanded,
                  previewLimit: _previewLimit,
                  onToggleContacts: () =>
                      setState(() => _contactsExpanded = !_contactsExpanded),
                  onToggleGroups: () =>
                      setState(() => _groupsExpanded = !_groupsExpanded),
                  onAddJid: (jid) => unawaited(_addContact(jid)),
                  onOpenBookmark: (row) => unawaited(_openBookmark(row)),
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

class _SearchResults extends StatelessWidget {
  const _SearchResults({
    required this.contacts,
    required this.bookmarks,
    required this.needle,
    required this.contactsExpanded,
    required this.groupsExpanded,
    required this.previewLimit,
    required this.onToggleContacts,
    required this.onToggleGroups,
    required this.onAddJid,
    required this.onOpenBookmark,
  });

  final List<AccountContact> contacts;
  final List<AccountBookmark> bookmarks;
  final String needle;
  final bool contactsExpanded;
  final bool groupsExpanded;
  final int previewLimit;
  final VoidCallback onToggleContacts;
  final VoidCallback onToggleGroups;
  final ValueChanged<String> onAddJid;
  final ValueChanged<AccountBookmark> onOpenBookmark;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tg = context.tg;

    final contactHits = contacts
        .where(
          (c) => matchesNameOrJid(
            name: c.displayName,
            jid: c.entry.jid,
            needle: needle,
          ),
        )
        .toList();
    final groupHits = bookmarks
        .where(
          (g) => matchesNameOrJid(
            name: g.bookmark.displayName,
            jid: g.bookmark.jid,
            needle: needle,
          ),
        )
        .toList();

    final addJid = completeJidCandidate(needle);
    final showAdd =
        addJid != null &&
        !contacts.any((c) => c.entry.jid.toLowerCase() == addJid.toLowerCase());

    if (!showAdd && contactHits.isEmpty && groupHits.isEmpty) {
      return Center(
        child: Text(
          l10n.noContactsMatch,
          style: TextStyle(color: tg.textSecondary),
        ),
      );
    }

    final rows = <Widget>[
      if (showAdd) AddJidTile(jid: addJid, onTap: () => onAddJid(addJid)),
      if (contactHits.isNotEmpty) ...[
        SearchSectionHeader(
          title: l10n.searchSectionContacts,
          count: contactHits.length,
        ),
        ...visibleSlice(
          contactHits,
          expanded: contactsExpanded,
          limit: previewLimit,
        ).map((e) => ContactRosterTile(entry: e)),
        if (contactHits.length > previewLimit)
          SearchExpandToggle(
            expanded: contactsExpanded,
            hiddenCount: contactHits.length - previewLimit,
            onTap: onToggleContacts,
          ),
      ],
      if (groupHits.isNotEmpty) ...[
        SearchSectionHeader(
          title: l10n.searchSectionGroups,
          count: groupHits.length,
        ),
        ...visibleSlice(
          groupHits,
          expanded: groupsExpanded,
          limit: previewLimit,
        ).map((g) => GroupBookmarkTile(row: g, onTap: () => onOpenBookmark(g))),
        if (groupHits.length > previewLimit)
          SearchExpandToggle(
            expanded: groupsExpanded,
            hiddenCount: groupHits.length - previewLimit,
            onTap: onToggleGroups,
          ),
      ],
    ];

    return ListView.separated(
      itemCount: rows.length,
      separatorBuilder: (context, i) {
        final cur = rows[i];
        if (cur is SearchSectionHeader || cur is SearchExpandToggle) {
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
