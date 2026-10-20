// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Chat list translated from Telegram for Android's `DialogsActivity`
// (GPL-2.0-or-later): 54dp avatar, two-line text column, unread badge,
// pinned affordance. Top pill searches messages (not add-contact).

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_slidable/flutter_slidable.dart';

import 'package:resonchat/account/account_hub.dart';
import 'package:resonchat/l10n/l10n.dart';
import 'package:resonchat/state/providers.dart';
import 'package:resonchat/ui/chat/chat_page.dart';
import 'package:resonchat/ui/chats/chat_row.dart';
import 'package:resonchat/ui/chats/chats_filter_bar.dart';
import 'package:resonchat/ui/chats/search.dart';
import 'package:resonchat/ui/chats/unread.dart';
import 'package:resonchat/ui/home/open_chat.dart';
import 'package:resonchat/ui/home/shell_actions.dart';
import 'package:resonchat/ui/theme.dart';

class ChatsPage extends ConsumerStatefulWidget {
  const ChatsPage({super.key, this.activeChatKey});

  /// Highlighted row in column mode (FluffyChat `activeChat`).
  final String? activeChatKey;

  @override
  ConsumerState<ChatsPage> createState() => _ChatsPageState();
}

class _ChatsPageState extends ConsumerState<ChatsPage>
    with SingleTickerProviderStateMixin {
  final _query = TextEditingController();
  String _needle = '';
  Timer? _debounce;

  /// Display-only: Messages vs Unread. Receiving is unchanged.
  ChatsListScope _scope = ChatsListScope.messages;

  /// Display-only: null = every account.
  String? _accountId;

  /// Account panel slides from this page’s start edge (right of the landscape
  /// [NavigationRail]), not from the window’s left via [Scaffold.drawer].
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
    _debounce?.cancel();
    _accountPanel.dispose();
    _query.dispose();
    super.dispose();
  }

  void _openAccountPanel() => unawaited(_accountPanel.forward());

  void _closeAccountPanel() => unawaited(_accountPanel.reverse());

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

    final hub = ref.watch(accountHubProvider);
    // If the filtered account was disabled, drop the filter so we do not
    // show an empty list while other enabled accounts still have chats —
    // and so we never keep pinning the UI to a session that no longer exists.
    final filterId = _accountId;
    if (filterId != null &&
        !hub.accounts.any((a) => a.id == filterId && a.enabled)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _accountId == filterId) {
          setState(() => _accountId = null);
        }
      });
    }

    return Scaffold(
      appBar: AppBar(
        // Filter hamburger opens the account panel; no AppBar drawer leading.
        automaticallyImplyLeading: false,
        title: Text(l10n.appName),
        actions: portraitShellActions(context),
      ),
      // ClipRect: SlideTransition moves the panel by its own width to the
      // left of this body. Without clipping it paints over the landscape
      // NavigationRail; with clipping it emerges from this page’s start
      // edge (= rail’s right edge).
      body: ClipRect(
        child: AnimatedBuilder(
          animation: _accountPanel,
          builder: (context, child) {
            final open = _accountPanel.status != AnimationStatus.dismissed;
            return Stack(
              children: [
                child!,
                if (open) ...[
                  Positioned.fill(
                    child: GestureDetector(
                      onTap: _closeAccountPanel,
                      behavior: HitTestBehavior.opaque,
                      child: ColoredBox(
                        color: Colors.black.withValues(
                          alpha: 0.32 * _accountPanel.value,
                        ),
                      ),
                    ),
                  ),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: SlideTransition(
                      position: _accountSlide,
                      child: ChatsAccountDrawer(
                        accounts: hub.accounts,
                        selectedAccountId: _accountId,
                        onSelected: (id) {
                          setState(() => _accountId = id);
                          _closeAccountPanel();
                        },
                      ),
                    ),
                  ),
                ],
              ],
            );
          },
          child: Column(
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
                              if (_accountId == null ||
                                  _messageMatchesAccount(
                                    m.chatJid,
                                    _accountId!,
                                  ))
                                SearchHit(
                                  chatJid: m.chatJid,
                                  chatTitle: titles[m.chatJid] ?? m.chatJid,
                                  body: m.body,
                                  time: m.timestamp,
                                  incoming: m.incoming,
                                  messageAnchor: unreadAnchorOf(m),
                                ),
                          ];
                          return _filteredScroll(
                            body: SearchResults(
                              hits: hits,
                              running: false,
                              onOpen: _openHit,
                            ),
                          );
                        },
                        loading: () => _filteredScroll(
                          body: SearchResults(
                            hits: const [],
                            running: true,
                            onOpen: (_) {},
                          ),
                        ),
                        error: (e, _) => _filteredScroll(
                          body: Center(
                            child: Text(
                              l10n.searchFailed('$e'),
                              style: TextStyle(color: context.tg.danger),
                            ),
                          ),
                        ),
                      )
                    : chats.when(
                        data: (list) {
                          final filtered = _applyFilters(list);
                          final emptyLabel = list.isEmpty
                              ? l10n.noConversationsYet
                              : (_scope == ChatsListScope.unread
                                    ? l10n.noUnreadConversations
                                    : l10n.noConversationsYet);
                          return SlidableAutoCloseBehavior(
                            child: CustomScrollView(
                              slivers: [
                                SliverToBoxAdapter(child: _filterBar()),
                                if (filtered.isEmpty)
                                  SliverFillRemaining(
                                    hasScrollBody: false,
                                    child: Center(child: Text(emptyLabel)),
                                  )
                                else
                                  SliverList.separated(
                                    itemCount: filtered.length,
                                    separatorBuilder: (_, _) => Padding(
                                      padding: const EdgeInsets.only(left: 82),
                                      child: Divider(
                                        height: 0.5,
                                        color: context.tg.separator,
                                      ),
                                    ),
                                    itemBuilder: (context, i) {
                                      final entry = filtered[i];
                                      final key = entry.ref.key;
                                      return ChatRow(
                                        key: ValueKey(key),
                                        entry: entry,
                                        showAccountChrome: _accountId == null,
                                        selected: widget.activeChatKey == key,
                                        onOpen: () => openChat(context, key),
                                      );
                                    },
                                  ),
                              ],
                            ),
                          );
                        },
                        loading: () =>
                            const Center(child: CircularProgressIndicator()),
                        error: (e, _) => Center(child: Text('$e')),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _filterBar() => ChatsFilterBar(
    scope: _scope,
    onScopeChanged: (s) => setState(() => _scope = s),
    onOpenAccounts: _openAccountPanel,
  );

  /// Filter header + nested scrollable body (search results).
  Widget _filteredScroll({required Widget body}) {
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: _filterBar()),
        SliverFillRemaining(hasScrollBody: true, child: body),
      ],
    );
  }

  List<AccountChat> _applyFilters(List<AccountChat> list) {
    Iterable<AccountChat> rows = list;
    final accountId = _accountId;
    if (accountId != null) {
      rows = rows.where((c) => c.account.id == accountId);
    }
    if (_scope == ChatsListScope.unread) {
      rows = rows.where(
        (c) => c.chat.unreadCount > 0 || c.chat.unreadMentions > 0,
      );
    }
    return rows.toList(growable: false);
  }

  /// Search hits store bare chat JID; resolve against the filtered account.
  bool _messageMatchesAccount(String chatJid, String accountId) {
    final list = ref.read(chatsProvider).asData?.value ?? const [];
    for (final c in list) {
      if (c.chat.jid == chatJid && c.account.id == accountId) return true;
    }
    return false;
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
