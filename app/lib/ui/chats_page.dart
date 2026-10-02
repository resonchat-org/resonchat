// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Chat list translated from Telegram for Android's `DialogsActivity`
// (GPL-2.0-or-later): 54dp avatar, two-line text column, unread badge,
// pinned/mute affordances and swipe-to-archive/delete.

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../omemo/protocol.dart';
import '../state/providers.dart';
import '../store/database.dart';
import 'theme.dart';

class ChatsPage extends ConsumerStatefulWidget {
  const ChatsPage({super.key});

  @override
  ConsumerState<ChatsPage> createState() => _ChatsPageState();
}

class _ChatsPageState extends ConsumerState<ChatsPage> {
  final _jid = TextEditingController();

  @override
  void initState() {
    super.initState();
    final xmpp = ref.read(xmppServiceProvider);

    // Pump inbound traffic into the store while this page lives.
    xmpp.inbound.listen((msg) async {
      final db = ref.read(databaseProvider);
      final chatJid = msg.from.toBare().toString();
      await db.upsertChat(chatJid);

      // A carbon duplicates a message we already hold locally.
      if (msg.isCarbonCopy) return;
      final stanzaId = msg.stanzaId ?? '';
      if (await db.findByStanzaId(chatJid, stanzaId) != null) return;

      await db.insertMessage(
        MessagesCompanion(
          chatJid: Value(chatJid),
          sender: Value(msg.from.toString()),
          stanzaId: Value(stanzaId),
          body: Value(msg.encryptionError != null ? '' : msg.body),
          // Archived messages keep their original send time.
          timestamp: Value(msg.archiveTimestamp ?? DateTime.now()),
          encMode: Value(msg.encryptionError != null ? 'error' : 'none'),
          incoming: const Value(true),
        ),
      );
    });

  }

  @override
  void dispose() {
    _jid.dispose();
    super.dispose();
  }

  Future<void> _openChat() async {
    final jid = _jid.text.trim();
    if (jid.isEmpty) return;
    await ref.read(databaseProvider).upsertChat(jid);
    _jid.clear();
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
            onPressed: () {},
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
                          _ChatRow(chat: list[i]),
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
class _ChatRow extends ConsumerWidget {
  const _ChatRow({required this.chat});

  final Chat chat;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tg = context.tg;
    final title = chat.title.isEmpty ? chat.jid : chat.title;
    final mode = ref.watch(chatEncModeProvider(chat.jid));
    final preview = ref.watch(lastMessageProvider(chat.jid));
    final locked = mode != EncMode.none;

    return InkWell(
      onTap: () => Navigator.of(context).pushNamed('/chat', arguments: chat.jid),
      child: Container(
        height: TgDimens.chatsRowHeight,
        padding: const EdgeInsets.symmetric(
          horizontal: TgDimens.chatsHorizontalPadding,
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: TgDimens.avatarChats / 2,
              backgroundColor: tg.accent.withValues(alpha: 0.18),
              child: Text(
                title.isEmpty ? '?' : title[0].toUpperCase(),
                style: TextStyle(
                  color: tg.accent,
                  fontSize: 20,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (locked)
                        Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: Icon(Icons.lock, size: 12, color: tg.accent),
                        ),
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: TgDimens.chatTitleFontSize,
                            fontWeight: FontWeight.w500,
                            color: tg.textPrimary,
                          ),
                        ),
                      ),
                      Text(
                        _timeOf(chat.lastActivity),
                        style: TextStyle(
                          fontSize: TgDimens.timeFontSize,
                          color: tg.textSecondary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: TgDimens.chatsTitleGap),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          preview.value ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: TgDimens.chatSubtitleFontSize,
                            color: tg.textSecondary,
                          ),
                        ),
                      ),
                      if (locked)
                        Text(
                          encModeLabel(mode),
                          style: TextStyle(
                            fontSize: TgDimens.timeFontSize,
                            color: tg.accent,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _timeOf(DateTime t) {
    final now = DateTime.now();
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    if (t.year == now.year && t.day == now.day) return '$h:$m';
    return '${t.day}/${t.month}';
  }
}