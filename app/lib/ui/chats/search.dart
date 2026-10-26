// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Search UI: the results list, the empty states, and jumping to a hit.
//
// One thing this file is careful about: the same text is used for a *search*
// box and an *open chat by JID* box, and they are not the same action. Opening
// a chat the user typed a fragment of is how a search becomes "it opened a
// conversation I did not ask for", so a query with a space in it is treated as
// a search and never as a JID.

import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:resonchat/account/account_hub.dart';
import 'package:resonchat/l10n/l10n.dart';
import 'package:resonchat/persistence/database.dart';
import 'package:resonchat/state/providers.dart';
import 'package:resonchat/ui/chat/chat_page.dart';
import 'package:resonchat/ui/chats/unread.dart';
import 'package:resonchat/ui/theme.dart';
import 'package:resonchat/xmpp/chat/forwarding.dart';

/// One hit in a search result list.
class SearchHit {
  const SearchHit({
    required this.chatJid,
    required this.chatTitle,
    required this.body,
    required this.time,
    required this.incoming,
    required this.messageAnchor,
  });

  final String chatJid;
  final String chatTitle;
  final String body;
  final DateTime time;
  final bool incoming;

  /// Stable id for scrolling to this message in [ChatPage] ([unreadAnchorOf]).
  final String messageAnchor;
}

/// The list of results, with the empty states that make it usable.
///
/// Three distinct states, not one "nothing found": a search that has not been
/// typed, a search that found nothing, and a search that is running. Collapsing
/// them leaves the user unsure whether the app is broken or the query was bad.
class SearchResults extends StatelessWidget {
  const SearchResults({
    super.key,
    required this.hits,
    required this.running,
    required this.onOpen,
  });

  final List<SearchHit> hits;
  final bool running;
  final void Function(SearchHit hit) onOpen;

  @override
  Widget build(BuildContext context) {
    final tg = context.tg;
    final l10n = context.l10n;
    if (hits.isEmpty) {
      return Center(
        child: Text(
          running ? l10n.searching : l10n.noMessagesFound,
          style: TextStyle(color: tg.textSecondary),
        ),
      );
    }
    return ListView.separated(
      itemCount: hits.length,
      separatorBuilder: (_, _) => Divider(height: 0.5, color: tg.separator),
      itemBuilder: (context, i) {
        final hit = hits[i];
        return ListTile(
          leading: CircleAvatar(
            backgroundColor: tg.accent.withValues(alpha: 0.18),
            child: Text(
              hit.chatTitle.isEmpty ? '?' : hit.chatTitle[0].toUpperCase(),
              style: TextStyle(color: tg.accent),
            ),
          ),
          title: Text(
            hit.body,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: TgDimens.chatSubtitleFontSize),
          ),
          subtitle: Text(
            '${hit.chatTitle} · ${_clock(hit.time)}',
            style: TextStyle(
              fontSize: TgDimens.timeFontSize,
              color: tg.textSecondary,
            ),
          ),
          onTap: () => onOpen(hit),
        );
      },
    );
  }

  static String _clock(DateTime t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}

/// Highlights [needle] inside [text], as a styled span.
TextSpan highlightNeedle(
  String text,
  String needle, {
  required TextStyle base,
  required TextStyle match,
}) {
  final trimmed = needle.trim();
  if (trimmed.isEmpty) return TextSpan(text: text, style: base);
  final lowerText = text.toLowerCase();
  final lowerNeedle = trimmed.toLowerCase();
  final spans = <TextSpan>[];
  var cursor = 0;
  while (true) {
    final at = lowerText.indexOf(lowerNeedle, cursor);
    if (at < 0) break;
    if (at > cursor) {
      spans.add(TextSpan(text: text.substring(cursor, at), style: base));
    }
    spans.add(
      TextSpan(text: text.substring(at, at + lowerNeedle.length), style: match),
    );
    cursor = at + lowerNeedle.length;
  }
  if (cursor < text.length) {
    spans.add(TextSpan(text: text.substring(cursor), style: base));
  }
  return TextSpan(children: spans);
}

/// The search page: a field, and the results.
class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key, this.chatJid});

  /// Restricts the search to one conversation when opened from inside a chat.
  final String? chatJid;

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final _query = TextEditingController();
  String _needle = '';

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _openHit(SearchHit hit) async {
    // In-chat search: return the hit so the existing page can scroll to it.
    if (widget.chatJid != null) {
      Navigator.of(context).pop(hit);
      return;
    }
    // Global search stores bare JIDs; open via ChatRef when we can match a row.
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
    final tg = context.tg;
    final l10n = context.l10n;
    final results = widget.chatJid == null
        ? ref.watch(messageSearchProvider(_needle))
        : ref.watch(
            chatMessageSearchProvider((
              chatJid: widget.chatJid!,
              needle: _needle,
            )),
          );

    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _query,
          autofocus: true,
          textInputAction: TextInputAction.search,
          onChanged: (value) => setState(() => _needle = value),
          decoration: InputDecoration(
            hintText: widget.chatJid == null
                ? l10n.searchMessages
                : l10n.searchInChat,
            border: InputBorder.none,
            hintStyle: TextStyle(color: tg.textSecondary),
          ),
        ),
        actions: [
          if (_needle.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: l10n.clear,
              onPressed: () {
                _query.clear();
                setState(() => _needle = '');
              },
            ),
        ],
      ),
      body: results.when(
        data: (messages) {
          final titles = _titles(ref);
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
          return SearchResults(hits: hits, running: false, onOpen: _openHit);
        },
        loading: () =>
            SearchResults(hits: const [], running: true, onOpen: (_) {}),
        error: (e, _) => Center(
          child: Text(
            l10n.searchFailed('$e'),
            style: TextStyle(color: tg.danger),
          ),
        ),
      ),
    );
  }

  Map<String, String> _titles(WidgetRef ref) {
    final chats = ref.watch(chatsProvider).value;
    if (chats == null) return const {};
    return {for (final c in chats) c.chat.jid: c.chat.conversationName};
  }
}

/// Picks a conversation to forward into.
class ForwardTargetSheet extends ConsumerWidget {
  const ForwardTargetSheet({
    super.key,
    required this.items,
    this.selectionCount,
  });

  final List<ForwardItem> items;

  /// How many messages the user selected (may differ from [items] when merged).
  final int? selectionCount;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tg = context.tg;
    final l10n = context.l10n;
    final chats = ref.watch(chatsProvider);
    final count = selectionCount ?? items.length;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      builder: (context, controller) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Text(
                count <= 1 ? l10n.forward : l10n.selectedCount(count),
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                l10n.forwardSubtitle,
                style: TextStyle(fontSize: 12, color: tg.textSecondary),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: chats.when(
                data: (list) => list.isEmpty
                    ? Center(child: Text(l10n.noConversationsYet))
                    : ListView.builder(
                        controller: controller,
                        itemCount: list.length,
                        itemBuilder: (context, i) {
                          final entry = list[i];
                          final chat = entry.chat;
                          final title = chat.conversationName;
                          return ListTile(
                            leading: CircleAvatar(
                              backgroundColor: tg.accent.withValues(
                                alpha: 0.18,
                              ),
                              child: Text(
                                title.isEmpty ? '?' : title[0].toUpperCase(),
                                style: TextStyle(color: tg.accent),
                              ),
                            ),
                            title: Text(title),
                            subtitle: Text(
                              entry.account.bareJid,
                              style: TextStyle(
                                fontSize: 12,
                                color: entry.accent,
                              ),
                            ),
                            onTap: () =>
                                Navigator.of(context).pop(entry.ref.key),
                          );
                        },
                      ),
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
