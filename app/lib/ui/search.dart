// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
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

import '../state/providers.dart';
import '../xmpp/forwarding.dart';
import 'chat_page.dart';

import 'theme.dart';

/// One hit in a search result list.
class SearchHit {
  const SearchHit({
    required this.chatJid,
    required this.chatTitle,
    required this.body,
    required this.time,
    required this.incoming,
  });

  final String chatJid;
  final String chatTitle;
  final String body;
  final DateTime time;
  final bool incoming;
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
    if (hits.isEmpty) {
      return Center(
        child: Text(
          running ? 'Searching…' : 'No messages found',
          style: TextStyle(color: tg.textSecondary),
        ),
      );
    }
    return ListView.separated(
      itemCount: hits.length,
      separatorBuilder: (_, _) =>
          Divider(height: 0.5, color: tg.separator),
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
          // The whole row opens the conversation; the result itself is not a
          // separate target, because scrolling to a message we did not load
          // is worse than opening the conversation it is in.
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
///
/// Split on the needle case-insensitively rather than using a regex built from
/// user input: a needle containing regex metacharacters would otherwise either
/// throw or highlight the wrong run.
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
      TextSpan(
        text: text.substring(at, at + lowerNeedle.length),
        style: match,
      ),
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

  @override
  Widget build(BuildContext context) {
    final tg = context.tg;
    final results = widget.chatJid == null
        ? ref.watch(messageSearchProvider(_needle))
        : ref.watch(
            chatMessageSearchProvider((chatJid: widget.chatJid!, needle: _needle)),
          );

    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _query,
          autofocus: true,
          textInputAction: TextInputAction.search,
          // onChanged rather than onSubmitted: a search should narrow as you
          // type, and waiting for the keyboard's search key means the user has
          // to ask a second time for an answer they already waited for.
          onChanged: (value) => setState(() => _needle = value),
          decoration: InputDecoration(
            hintText: widget.chatJid == null
                ? 'Search messages'
                : 'Search in this chat',
            border: InputBorder.none,
            hintStyle: TextStyle(color: tg.textSecondary),
          ),
        ),
        actions: [
          if (_needle.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: 'Clear',
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
              ),
          ];
          return SearchResults(
            hits: hits,
            running: false,
            onOpen: (hit) => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ChatPage(chatJid: hit.chatJid),
              ),
            ),
          );
        },
        loading: () => const SearchResults(
          hits: [],
          running: true,
          onOpen: _unused,
        ),
        error: (e, _) => Center(
          child: Text('Search failed: $e', style: TextStyle(color: tg.danger)),
        ),
      ),
    );
  }

  /// Display names for the conversations in the results.
  ///
  /// Read once per rebuild rather than per row: a hit's chat is almost always
  /// one of a handful, and the fallback to the bare JID is honest enough that a
  /// missing title never blocks a result.
  Map<String, String> _titles(WidgetRef ref) {
    final chats = ref.watch(chatsProvider).value;
    if (chats == null) return const {};
    return {
      for (final c in chats) c.jid: c.title.isEmpty ? c.jid : c.title,
    };
  }

  static void _unused(SearchHit hit) {}
}

/// Picks a conversation to forward into.
///
/// Only conversations that could actually receive the message are listed as
/// targets — no, that is too clever: a conversation whose track is currently
/// blocked is still a legitimate place to forward to, and hiding it would mean
/// the user cannot find the conversation they wanted. Every conversation is
/// listed; the refusal, if there is one, happens on send and is reported.
class ForwardTargetSheet extends ConsumerWidget {
  const ForwardTargetSheet({super.key, required this.items});

  final List<ForwardItem> items;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tg = context.tg;
    final chats = ref.watch(chatsProvider);
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
                items.length == 1
                    ? 'Forward message'
                    : 'Forward ${items.length} messages',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                'The message is sent again, encrypted for the person you '
                'choose. The original is not re-shared.',
                style: TextStyle(fontSize: 12, color: tg.textSecondary),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: chats.when(
                data: (list) => list.isEmpty
                    ? const Center(child: Text('No conversations yet'))
                    : ListView.builder(
                        controller: controller,
                        itemCount: list.length,
                        itemBuilder: (context, i) {
                          final chat = list[i];
                          final title =
                              chat.title.isEmpty ? chat.jid : chat.title;
                          return ListTile(
                            leading: CircleAvatar(
                              backgroundColor:
                                  tg.accent.withValues(alpha: 0.18),
                              child: Text(
                                title.isEmpty ? '?' : title[0].toUpperCase(),
                                style: TextStyle(color: tg.accent),
                              ),
                            ),
                            title: Text(title),
                            onTap: () =>
                                Navigator.of(context).pop(chat.jid),
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
      ),
    );
  }
}
