// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../omemo/protocol.dart';
import '../state/providers.dart';
import '../store/database.dart';
import 'theme.dart';

/// M1 chat list: roster-derived chats with unread-free minimal rows.
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

      // A carbon duplicates a message we already have locally.
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

    // XEP-0184: flip our outgoing messages to "delivered".
    xmpp.deliveryReceipts.listen((receipt) async {
      await ref.read(databaseProvider).markDelivered(
            receipt.from.toBare().toString(),
            receipt.stanzaId,
          );
    });
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
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.of(context).pushNamed('/settings'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _jid,
                    decoration: const InputDecoration(
                      labelText: 'Open chat (JID)',
                    ),
                    onSubmitted: (_) => _openChat(),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.chat),
                  onPressed: _openChat,
                ),
              ],
            ),
          ),
          Expanded(
            child: chats.when(
              data: (list) => ListView.builder(
                itemCount: list.length,
                itemBuilder: (context, i) {
                  final chat = list[i];
                  final mode = ref.watch(encModeProvider(chat.jid));
                  return ListTile(
                    leading: CircleAvatar(
                      child: Text(
                        chat.title.isEmpty ? '?' : chat.title[0].toUpperCase(),
                      ),
                    ),
                    title: Text(
                      chat.title.isEmpty ? chat.jid : chat.title,
                    ),
                    subtitle: Text(chat.jid),
                    trailing: EncBadge(
                      label: encModeLabel(mode),
                      locked: mode != EncMode.none,
                    ),
                    onTap: () => Navigator.of(context)
                        .pushNamed('/chat', arguments: chat.jid),
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
}
