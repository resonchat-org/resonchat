// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Chat list translated from Telegram for Android's `DialogsActivity`
// (GPL-2.0-or-later): 54dp avatar, two-line text column, unread badge,
// pinned/mute affordances and swipe-to-archive/delete.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/providers.dart';
import '../accounts/accounts_icon.dart';
import '../archive/archive_page.dart';
import '../home/open_chat.dart';
import '../requests/requests_page.dart';
import '../room/room_sheet.dart';
import '../theme.dart';
import 'chats_viewmodel.dart';
import 'chat_row.dart';
import 'search.dart';

class ChatsPage extends ConsumerStatefulWidget {
  const ChatsPage({super.key, this.activeChatKey});

  /// Highlighted row in column mode (FluffyChat `activeChat`).
  final String? activeChatKey;

  @override
  ConsumerState<ChatsPage> createState() => _ChatsPageState();
}

class _ChatsPageState extends ConsumerState<ChatsPage> {
  final _jid = TextEditingController();

  @override
  void dispose() {
    _jid.dispose();
    super.dispose();
  }

  /// Opens a conversation, adding the contact first when online.
  Future<void> _openChat() async {
    final raw = _jid.text.trim();
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
    _jid.clear();
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
    final chats = ref.watch(chatsProvider);
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.appName),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: l10n.searchMessages,
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute<void>(builder: (_) => const SearchPage())),
          ),
          IconButton(
            icon: const Icon(Icons.person_add_alt),
            tooltip: l10n.contactRequests,
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const RequestsPage()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.group_add_outlined),
            tooltip: l10n.joinGroup,
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              isScrollControlled: true,
              builder: (_) => const JoinRoomSheet(),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.archive_outlined),
            tooltip: l10n.archived,
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const ArchivePage()),
            ),
          ),
          IconButton(
            // CustomPaint: MaterialIcons in this AppBar slot paint blank on
            // some Linux builds even when the glyph exists in the OTF.
            icon: const AccountsIcon(),
            tooltip: l10n.manageAccounts,
            onPressed: () => Navigator.of(context).pushNamed('/accounts'),
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
          _OpenChatBar(controller: _jid, onOpen: _openChat),
          Expanded(
            child: chats.when(
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
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('$e')),
            ),
          ),
        ],
      ),
    );
  }
}

/// "Open chat by JID" affordance; replaced by search in later milestones.
class _OpenChatBar extends StatelessWidget {
  const _OpenChatBar({required this.controller, required this.onOpen});

  final TextEditingController controller;
  final VoidCallback onOpen;

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
        onSubmitted: (_) => onOpen(),
        style: TextStyle(fontSize: TgDimens.chatSubtitleFontSize),
        decoration: InputDecoration(
          isDense: true,
          hintText: l10n.openChatHint,
          hintStyle: TextStyle(color: tg.textSecondary),
          prefixIcon: Icon(Icons.search, size: 18, color: tg.textSecondary),
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
