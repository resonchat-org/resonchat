// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:moxxmpp/moxxmpp.dart' show JID;

import '../omemo/protocol.dart';
import '../state/providers.dart';
import '../store/database.dart';
import '../xmpp/connection.dart';
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
  var _lastTypingSent = false;

  /// Sends a composing notification at most once per burst of typing
  /// (XEP-0085); the peer gets one update, not one per keystroke.
  void _notifyTyping() {
    if (_input.text.isNotEmpty && _lastTypingSent) return;
    _lastTypingSent = _input.text.isNotEmpty;
    if (_input.text.isEmpty) return;
    // Fire-and-forget: a failed typing hint must never block typing.
    unawaited(
      ref.read(xmppServiceProvider).sendChatState(
            JID.fromString(widget.chatJid),
            TypingState.composing,
          ),
    );
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    final xmpp = ref.read(xmppServiceProvider);
    final stanzaId = await xmpp.sendPlainText(
      JID.fromString(widget.chatJid),
      text,
    );
    await ref.read(databaseProvider).insertMessage(
          MessagesCompanion(
            chatJid: Value(widget.chatJid),
            sender: const Value('me'),
            stanzaId: Value(stanzaId ?? ''),
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
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 260),
                            child: Text(
                              m.body,
                              style: const TextStyle(
                                fontSize: AppThemeTokens.messageFontSize,
                              ),
                            ),
                          ),
                          if (mine) ...[
                            const SizedBox(width: 6),
                            // Single check = sent, double check = delivered.
                            Icon(
                              m.delivered ? Icons.done_all : Icons.done,
                              size: 14,
                            ),
                          ],
                        ],
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
                    // XEP-0085: tell the peer we are typing.
                    onChanged: (_) => _notifyTyping(),
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
