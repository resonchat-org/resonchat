// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Chat list translated from Telegram for Android's `DialogsActivity`
// (GPL-2.0-or-later): 54dp avatar, two-line text column, unread badge,
// pinned/mute affordances and swipe-to-archive/delete.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:moxxmpp/moxxmpp.dart'
    show JID, RosterManager, rosterManager;
import '../xmpp/connection.dart';

import '../state/providers.dart';
import 'chat_row.dart';
import 'search.dart';
import 'theme.dart';

class ChatsPage extends ConsumerStatefulWidget {
  const ChatsPage({super.key});

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

  /// Opens a conversation with [jid], adding the contact first.
  ///
  /// Merely creating a local row is not enough: a server only routes stanzas
  /// between accounts that are in each other's roster, so a chat opened this
  /// way would silently never receive anything. Adding the contact and
  /// asking for the subscription is what makes it a real conversation.
  Future<void> _openChat() async {
    final raw = _jid.text.trim();
    if (raw.isEmpty) return;
    final jid = bareJidOf(raw);
    if (jid == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('That does not look like a JID')),
      );
      return;
    }

    final xmpp = ref.read(xmppServiceProvider);
    final db = ref.read(databaseProvider);
    await db.upsertChat(jid);
    _jid.clear();

    if (xmpp.state == XmppConnectionState.connected) {
      final roster =
          xmpp.connection?.getManagerById<RosterManager>(rosterManager);
      final added = await roster?.addToRoster(jid, jid) ?? false;
      if (added) {
        await xmpp.requestSubscription(JID.fromString(jid));
        await xmpp.subscribePeerPep(JID.fromString(jid));
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            added
                ? 'Contact request sent. Messages stay on this device '
                    'until they accept.'
                : 'Could not add the contact on the server.',
          ),
        ),
      );
    }
    if (mounted) Navigator.of(context).pushNamed('/chat', arguments: jid);
  }


  @override
  Widget build(BuildContext context) {
    final chats = ref.watch(chatsProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('resonchat'),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: 'Search messages',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SearchPage()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.settings),
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
                  ? const Center(child: Text('No conversations yet'))
                  : ListView.separated(
                      itemCount: list.length,
                      separatorBuilder: (_, _) => Padding(
                        padding: const EdgeInsets.only(left: 82),
                        child: Divider(height: 0.5, color: context.tg.separator),
                      ),
                      itemBuilder: (context, i) =>
                          ChatRow(
                      chat: list[i],
                      onOpen: () => Navigator.of(context)
                          .pushNamed('/chat', arguments: list[i].jid),
                    ),
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
}

/// "Open chat by JID" affordance; replaced by search in later milestones.
class _OpenChatBar extends StatelessWidget {
  const _OpenChatBar({required this.controller, required this.onOpen});

  final TextEditingController controller;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final tg = context.tg;
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
          hintText: 'Open chat (JID)',
          hintStyle: TextStyle(color: tg.textSecondary),
          prefixIcon: Icon(Icons.search, size: 18, color: tg.textSecondary),
          filled: true,
          fillColor: tg.separator.withValues(alpha: 0.35),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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

/// One conversation row.


/// Reduces whatever the user typed to a bare JID, or null if it is not one.
///
/// `user@example.org/phone` and `user@example.org` are the same contact for
/// roster purposes; only the bare form belongs in the roster, and putting a
/// full JID there silently creates a second, unreachable entry.
String? bareJidOf(String raw) {
  final trimmed = raw.trim();
  final slash = trimmed.indexOf('/');
  final bare = slash == -1 ? trimmed : trimmed.substring(0, slash);
  final parts = bare.split('@');
  if (parts.length != 2 || parts[0].isEmpty || parts[1].isEmpty) return null;
  // A domain must look like a domain, not a fragment of one.
  if (parts[1].contains(' ')) return null;
  return bare;
}
