// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Chat list translated from Telegram for Android's `DialogsActivity`
// (GPL-2.0-or-later): 54dp avatar, two-line text column, unread badge,
// pinned affordance. Top pill searches messages (not add-contact).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../account/account_hub.dart';
import '../../l10n/l10n.dart';
import '../../state/providers.dart';
import '../chat/chat_page.dart';
import '../home/open_chat.dart';
import '../pending/pending_requests_page.dart';
import '../room/create_group_sheet.dart';
import '../theme.dart';
import 'chat_row.dart';
import 'search.dart';
import 'unread.dart';

class ChatsPage extends ConsumerStatefulWidget {
  const ChatsPage({super.key, this.activeChatKey});

  /// Highlighted row in column mode (FluffyChat `activeChat`).
  final String? activeChatKey;

  @override
  ConsumerState<ChatsPage> createState() => _ChatsPageState();
}

class _ChatsPageState extends ConsumerState<ChatsPage> {
  final _query = TextEditingController();
  String _needle = '';
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 280), () {
      if (mounted) setState(() => _needle = value.trim());
    });
  }

  Future<void> _openHit(SearchHit hit) async {
    final chats = await accountHub.snapshotChats();
    final match = chats.where((c) => c.chat.jid == hit.chatJid).firstOrNull;
    final key = match?.ref.key ?? hit.chatJid;
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            ChatPage(chatJid: key, focusMessageAnchor: hit.messageAnchor),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final chats = ref.watch(chatsProvider);
    final l10n = context.l10n;
    final searching = _needle.isNotEmpty;
    final results = searching
        ? ref.watch(messageSearchProvider(_needle))
        : null;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.appName),
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
            onPressed: () => unawaited(showGroupActionsSheet(context)),
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
          _MessageSearchBar(
            controller: _query,
            onChanged: _onQueryChanged,
            onClear: () {
              _query.clear();
              setState(() => _needle = '');
            },
            hasQuery: _needle.isNotEmpty || _query.text.isNotEmpty,
          ),
          Expanded(
            child: searching
                ? results!.when(
                    data: (messages) {
                      final titles = _chatTitles(ref);
                      final hits = [
                        for (final m in messages)
                          SearchHit(
                            chatJid: m.chatJid,
                            chatTitle: titles[m.chatJid] ?? m.chatJid,
                            body: m.body,
                            time: m.timestamp,
                            incoming: m.incoming,
                            messageAnchor: unreadAnchorOf(m),
                          ),
                      ];
                      return SearchResults(
                        hits: hits,
                        running: false,
                        onOpen: _openHit,
                      );
                    },
                    loading: () => SearchResults(
                      hits: const [],
                      running: true,
                      onOpen: (_) {},
                    ),
                    error: (e, _) => Center(
                      child: Text(
                        l10n.searchFailed('$e'),
                        style: TextStyle(color: context.tg.danger),
                      ),
                    ),
                  )
                : chats.when(
                    data: (list) => list.isEmpty
                        ? Center(child: Text(l10n.noConversationsYet))
                        : ListView.separated(
                            itemCount: list.length,
                            separatorBuilder: (_, _) => Padding(
                              padding: const EdgeInsets.only(left: 82),
                              child: Divider(
                                height: 0.5,
                                color: context.tg.separator,
                              ),
                            ),
                            itemBuilder: (context, i) {
                              final entry = list[i];
                              final key = entry.ref.key;
                              return ChatRow(
                                entry: entry,
                                selected: widget.activeChatKey == key,
                                onOpen: () => openChat(context, key),
                              );
                            },
                          ),
                    loading: () =>
                        const Center(child: CircularProgressIndicator()),
                    error: (e, _) => Center(child: Text('$e')),
                  ),
          ),
        ],
      ),
    );
  }

  Map<String, String> _chatTitles(WidgetRef ref) {
    final list = ref.read(chatsProvider).asData?.value ?? const [];
    return {
      for (final c in list)
        c.chat.jid: c.chat.title.isEmpty ? c.chat.jid : c.chat.title,
    };
  }
}

class _MessageSearchBar extends StatelessWidget {
  const _MessageSearchBar({
    required this.controller,
    required this.onChanged,
    required this.onClear,
    required this.hasQuery,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;
  final bool hasQuery;

  @override
  Widget build(BuildContext context) {
    final tg = context.tg;
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        TgDimens.chatsHorizontalPadding,
        8,
        TgDimens.chatsHorizontalPadding,
        8,
      ),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        textInputAction: TextInputAction.search,
        style: TextStyle(fontSize: TgDimens.chatSubtitleFontSize),
        decoration: InputDecoration(
          isDense: true,
          hintText: l10n.searchMessages,
          hintStyle: TextStyle(color: tg.textSecondary),
          prefixIcon: Icon(Icons.search, size: 18, color: tg.textSecondary),
          suffixIcon: hasQuery
              ? IconButton(
                  icon: Icon(Icons.close, size: 18, color: tg.textSecondary),
                  tooltip: l10n.clear,
                  onPressed: onClear,
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
    );
  }
}
