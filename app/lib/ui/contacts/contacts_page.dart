// Copyright (C) 2026 ResonChat contributors.
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
import '../account_filter_overlay.dart';
import '../home/open_chat.dart';
import '../home/shell_actions.dart';
import '../room/room_sheet.dart';
import '../theme.dart';
import 'contacts_match.dart';
import 'contacts_tiles.dart';
import 'contacts_viewmodel.dart';

class ContactsPage extends ConsumerStatefulWidget {
  const ContactsPage({super.key});

  @override
  ConsumerState<ContactsPage> createState() => _ContactsPageState();
}

class _ContactsPageState extends ConsumerState<ContactsPage>
    with SingleTickerProviderStateMixin {
  static const _previewLimit = 3;

  final _query = TextEditingController();
  String _needle = '';
  bool _contactsExpanded = false;
  bool _groupsExpanded = false;

  /// Display-only: null = every account (same as ChatsPage).
  String? _accountId;

  late final AnimationController _accountPanel;
  late final Animation<Offset> _accountSlide;

  @override
  void initState() {
    super.initState();
    _accountPanel = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    );
    _accountSlide = Tween<Offset>(begin: const Offset(-1, 0), end: Offset.zero)
        .animate(
          CurvedAnimation(parent: _accountPanel, curve: Curves.easeOutCubic),
        );
  }

  @override
  void dispose() {
    _accountPanel.dispose();
    _query.dispose();
    super.dispose();
  }

  void _openAccountPanel() => unawaited(_accountPanel.forward());

  void _closeAccountPanel() => unawaited(_accountPanel.reverse());

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

  Future<void> _promptAddContact() async {
    final raw = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _AddContactSheet(),
    );
    if (raw == null || raw.isEmpty || !mounted) return;
    await _addContact(raw);
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
    // Conversations: a channel address is joined, never rostered as a contact.
    if (result.isMuc) {
      _clearQuery();
      final room = result.mucJid;
      if (result.chatKey != null) {
        openChat(context, result.chatKey!);
        return;
      }
      if (room != null) {
        await showJoinRoomSheet(context, initialRoomJid: room);
      }
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

  List<AccountContact> _filterContacts(List<AccountContact> list) {
    final id = _accountId;
    if (id == null) return list;
    return list.where((c) => c.account.id == id).toList();
  }

  List<AccountBookmark> _filterBookmarks(List<AccountBookmark> list) {
    final id = _accountId;
    if (id == null) return list;
    return list.where((b) => b.account.id == id).toList();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tg = context.tg;
    final hub = ref.watch(accountHubProvider);
    final filterId = _accountId;
    if (filterId != null &&
        !hub.accounts.any((a) => a.id == filterId && a.enabled)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _accountId == filterId) {
          setState(() => _accountId = null);
        }
      });
    }

    final roster = ref.watch(rosterProvider);
    final bookmarks = ref.watch(bookmarksProvider);
    final bookmarkList = _filterBookmarks(
      bookmarks.asData?.value ?? const <AccountBookmark>[],
    );
    final bookmarkCount = bookmarkList.length;
    final searching = _needle.trim().isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Text(l10n.tabContacts),
        actions: portraitShellActions(context),
      ),
      body: AccountFilterOverlay(
        controller: _accountPanel,
        slide: _accountSlide,
        accounts: hub.accounts,
        selectedAccountId: _accountId,
        onDismiss: _closeAccountPanel,
        onSelected: (id) {
          setState(() => _accountId = id);
          _closeAccountPanel();
        },
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                TgDimens.chatsHorizontalPadding,
                8,
                TgDimens.chatsHorizontalPadding,
                8,
              ),
              child: Row(
                children: [
                  AccountFilterMenuButton(onPressed: _openAccountPanel),
                  const SizedBox(width: 8),
                  Expanded(
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
                ],
              ),
            ),
            Expanded(
              child: roster.when(
                data: (list) {
                  final contacts = _filterContacts(list);
                  if (!searching) {
                    return IdleContactsList(
                      contacts: contacts,
                      bookmarkCount: bookmarkCount,
                      filterAccountId: _accountId,
                      onAddContact: () => unawaited(_promptAddContact()),
                    );
                  }
                  return _SearchResults(
                    contacts: contacts,
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
                    onAddGroup: (jid) => unawaited(
                      showJoinRoomSheet(context, initialRoomJid: jid),
                    ),
                    onOpenBookmark: (row) => unawaited(_openBookmark(row)),
                    showAccountColor: _accountId == null,
                  );
                },
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => Center(child: Text('$e')),
              ),
            ),
          ],
        ),
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
    required this.onAddGroup,
    required this.onOpenBookmark,
    required this.showAccountColor,
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
  final ValueChanged<String> onAddGroup;
  final ValueChanged<AccountBookmark> onOpenBookmark;
  final bool showAccountColor;

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
    final showAddContact =
        addJid != null &&
        !contacts.any((c) => c.entry.jid.toLowerCase() == addJid.toLowerCase());
    final showAddGroup =
        addJid != null &&
        !bookmarks.any(
          (g) => g.bookmark.jid.toLowerCase() == addJid.toLowerCase(),
        );

    if (!showAddContact &&
        !showAddGroup &&
        contactHits.isEmpty &&
        groupHits.isEmpty) {
      return Center(
        child: Text(
          l10n.noContactsMatch,
          style: TextStyle(color: tg.textSecondary),
        ),
      );
    }

    final rows = <Widget>[
      if (addJid != null && showAddContact)
        AddJidTile(jid: addJid, onTap: () => onAddJid(addJid)),
      if (addJid != null && showAddGroup)
        AddGroupTile(jid: addJid, onTap: () => onAddGroup(addJid)),
      if (contactHits.isNotEmpty) ...[
        SearchSectionHeader(
          title: l10n.searchSectionContacts,
          count: contactHits.length,
        ),
        ...visibleSlice(
          contactHits,
          expanded: contactsExpanded,
          limit: previewLimit,
        ).map(
          (e) =>
              ContactRosterTile(entry: e, showAccountColor: showAccountColor),
        ),
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
        ).map(
          (g) => GroupBookmarkTile(
            row: g,
            showAccountColor: showAccountColor,
            onTap: () => onOpenBookmark(g),
          ),
        ),
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

/// Same shape as the join-room sheet: a short form pulled up from the bottom.
class _AddContactSheet extends StatefulWidget {
  const _AddContactSheet();

  @override
  State<_AddContactSheet> createState() => _AddContactSheetState();
}

class _AddContactSheetState extends State<_AddContactSheet> {
  final _jid = TextEditingController();

  @override
  void dispose() {
    _jid.dispose();
    super.dispose();
  }

  void _submit() {
    final raw = _jid.text.trim();
    if (raw.isEmpty) return;
    Navigator.of(context).pop(raw);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 16, 20, bottom + 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.addContact, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          TextField(
            controller: _jid,
            autofocus: true,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: l10n.jid,
              hintText: l10n.addContactHint,
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: _submit, child: Text(l10n.addContact)),
        ],
      ),
    );
  }
}
