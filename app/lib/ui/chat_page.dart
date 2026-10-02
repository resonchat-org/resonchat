// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Chat page. Layout and interactions follow Telegram for Android's
// `ChatActivity` (GPL-2.0-or-later), translated to Flutter.

import 'dart:async';

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:moxxmpp/moxxmpp.dart' show JID;

import '../omemo/protocol.dart';
import '../state/providers.dart';
import '../store/database.dart';
import '../xmpp/connection.dart';
import 'message_bubble.dart';
import 'theme.dart';

class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({super.key, required this.chatJid});

  final String chatJid;

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _focus = FocusNode();

  bool _typingNotified = false;
  bool _atBottom = true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll
      ..removeListener(_onScroll)
      ..dispose();
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final distance = _scroll.position.maxScrollExtent - _scroll.offset;
    final atBottom = distance < 80;
    if (atBottom != _atBottom) setState(() => _atBottom = atBottom);
  }

  void _scrollToBottom() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      _scroll.position.maxScrollExtent,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  /// XEP-0085: notify once per typing burst, not per keystroke.
  void _onInputChanged(String value) {
    final composing = value.trim().isNotEmpty;
    if (composing == _typingNotified) return;
    _typingNotified = composing;
    if (!composing) return;
    unawaited(
      ref
          .read(xmppServiceProvider)
          .sendChatState(JID.fromString(widget.chatJid), TypingState.composing),
    );
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    _typingNotified = false;
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
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  Future<void> _loadHistory() async {
    final count = await ref
        .read(xmppServiceProvider)
        .fetchHistory(JID.fromString(widget.chatJid));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          count == null
              ? 'Could not load history (server may not support MAM)'
              : 'Loaded $count archived message(s)',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tg = context.tg;
    final messages = ref.watch(messagesProvider(widget.chatJid));
    final mode = ref.watch(encModeProvider(widget.chatJid));

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            const CircleAvatar(
              radius: TgDimens.avatarChat / 2,
              child: Icon(Icons.person, size: 20),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    widget.chatJid,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    encModeLabel(mode),
                    style: TextStyle(
                      fontSize: TgDimens.timeFontSize,
                      fontWeight: FontWeight.w400,
                      color: Colors.white70,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          EncBadge(
            label: encModeLabel(mode),
            locked: mode != EncMode.none,
            onTap: () => Navigator.of(context)
                .pushNamed('/encryption', arguments: widget.chatJid),
          ),
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: 'Load history (MAM)',
            onPressed: _loadHistory,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Container(
              color: tg.pageBackground,
              child: messages.when(
                data: (list) => _MessageList(
                  messages: list,
                  scroll: _scroll,
                  onRetryDecrypt: () =>
                      _loadHistory(),
                ),
                loading: () =>
                    const Center(child: CircularProgressIndicator()),
                error: (e, _) => Center(child: Text('$e')),
              ),
            ),
          ),
          _InputBar(
            controller: _input,
            focusNode: _focus,
            onChanged: _onInputChanged,
            onSend: _send,
          ),
        ],
      ),
      floatingActionButton: _atBottom
          ? null
          : FloatingActionButton.small(
              backgroundColor: tg.peerBubble,
              foregroundColor: tg.accent,
              onPressed: _scrollToBottom,
              child: const Icon(Icons.keyboard_arrow_down),
            ),
    );
  }
}

/// Message list with day separators and an unread marker.
class _MessageList extends StatelessWidget {
  const _MessageList({
    required this.messages,
    required this.scroll,
    required this.onRetryDecrypt,
  });

  final List<Message> messages;
  final ScrollController scroll;
  final VoidCallback onRetryDecrypt;

  @override
  Widget build(BuildContext context) {
    if (messages.isEmpty) {
      return const Center(child: Text('No messages yet'));
    }

    final rows = <Widget>[];
    DateTime? lastDay;
    bool unreadMarked = false;

    for (final m in messages) {
      final day = DateTime(m.timestamp.year, m.timestamp.month, m.timestamp.day);
      if (lastDay == null || day != lastDay) {
        rows.add(DateSeparator(date: m.timestamp));
        lastDay = day;
        if (!unreadMarked) {
          // Mark the boundary once: everything above is history.
          unreadMarked = true;
        }
      }
      if (m.encMode == 'error') {
        rows.add(
          ListTile(
            dense: true,
            leading: Icon(
              Icons.lock_outline,
              size: 18,
              color: context.tg.danger,
            ),
            title: Text(
              'Unable to decrypt this message.',
              style: TextStyle(
                fontStyle: FontStyle.italic,
                color: context.tg.textSecondary,
              ),
            ),
            trailing: TextButton(
              onPressed: onRetryDecrypt,
              child: const Text('Retry'),
            ),
          ),
        );
        continue;
      }
      rows.add(
        MessageBubble(
          text: m.body,
          time: m.timestamp,
          side:
              m.incoming ? BubbleSide.incoming : BubbleSide.outgoing,
          delivered: m.delivered,
          failed: false,
        ),
      );
    }

    return ListView(
      controller: scroll,
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: rows,
    );
  }
}

/// Bottom input bar: attach button, text field, and a button that becomes
/// a microphone whenever the field is empty (docs/05 §4.2).
class _InputBar extends StatelessWidget {
  const _InputBar({
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.onSend,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final tg = context.tg;
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        final empty = value.text.trim().isEmpty;
        return Container(
          decoration: BoxDecoration(
            color: tg.pageBackground,
            border: Border(top: BorderSide(color: tg.separator)),
          ),
          padding: const EdgeInsets.fromLTRB(4, 6, 4, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              IconButton(
                icon: const Icon(Icons.attach_file),
                color: tg.textSecondary,
                onPressed: () {},
              ),
              Expanded(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 120),
                  child: TextField(
                    controller: controller,
                    focusNode: focusNode,
                    minLines: 1,
                    maxLines: 5,
                    textInputAction: TextInputAction.newline,
                    onChanged: onChanged,
                    style: TextStyle(
                      fontSize: TgDimens.messageFontSize,
                      color: tg.textPrimary,
                    ),
                    decoration: InputDecoration(
                      isDense: true,
                      filled: true,
                      fillColor: tg.pageBackground,
                      hintText: 'Message',
                      hintStyle: TextStyle(color: tg.textSecondary),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(18),
                        borderSide: BorderSide(color: tg.separator),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(18),
                        borderSide: BorderSide(color: tg.separator),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(18),
                        borderSide: BorderSide(color: tg.accent),
                      ),
                    ),
                  ),
                ),
              ),
              IconButton(
                icon: Icon(empty ? Icons.mic_none : Icons.send),
                color: tg.accent,
                onPressed: empty ? () {} : onSend,
              ),
            ],
          ),
        );
      },
    );
  }
}

