// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:moxxmpp/moxxmpp.dart' show JID;

import '../omemo/protocol.dart';
import '../state/providers.dart';
import '../store/database.dart';
import 'theme.dart';

/// M1 chat page: message bubbles + input bar. Encryption badge in the
/// app bar flips to OMEMO/PQ once the M4 state machine drives it.
class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({super.key, required this.chatJid});

  final String chatJid;

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    final xmpp = ref.read(xmppServiceProvider);
    await xmpp.sendPlainText(JID.fromString(widget.chatJid), text);
    await ref.read(databaseProvider).insertMessage(
          MessagesCompanion(
            chatJid: Value(widget.chatJid),
            sender: const Value('me'),
            body: Value(text),
            timestamp: Value(DateTime.now()),
            encMode: Value(
              ref.read(encModeProvider(widget.chatJid)).name,
            ),
            incoming: const Value(false),
          ),
        );
  }

  @override
  Widget build(BuildContext context) {
    final messages = ref.watch(messagesProvider(widget.chatJid));
    final mode = ref.watch(encModeProvider(widget.chatJid));
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.chatJid),
        actions: [
          EncBadge(
            label: encModeLabel(mode),
            locked: mode != EncMode.none,
          ),
          IconButton(
            icon: const Icon(Icons.verified_user),
            onPressed: () => Navigator.of(context)
                .pushNamed('/encryption', arguments: widget.chatJid),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: messages.when(
              data: (list) => ListView.builder(
                controller: _scroll,
                itemCount: list.length,
                itemBuilder: (context, i) {
                  final m = list[i];
                  final mine = !m.incoming;
                  if (m.encMode == 'error') {
                    return const ListTile(
                      title: Text(
                        'Unable to decrypt this message.',
                        style: TextStyle(fontStyle: FontStyle.italic),
                      ),
                    );
                  }
                  return Align(
                    alignment: mine
                        ? Alignment.centerRight
                        : Alignment.centerLeft,
                    child: Container(
                      margin: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: mine
                            ? Theme.of(context).colorScheme.primaryContainer
                            : Theme.of(context).colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(
                          AppThemeTokens.bubbleRadius,
                        ),
                      ),
                      child: Text(
                        m.body,
                        style: const TextStyle(
                          fontSize: AppThemeTokens.messageFontSize,
                        ),
                      ),
                    ),
                  );
                },
              ),
              loading: () =>
                  const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('$e')),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    decoration: const InputDecoration(
                      hintText: 'Message',
                    ),
                    onSubmitted: (_) => _send(),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.send),
                  onPressed: _send,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
