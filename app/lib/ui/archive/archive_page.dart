// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/providers.dart';
import '../chats/chat_row.dart';
import '../home/open_chat.dart';
import '../theme.dart';

class ArchivePage extends ConsumerWidget {
  const ArchivePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tg = context.tg;
    final l10n = context.l10n;
    final archived = ref.watch(archivedChatsProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.archived)),
      body: archived.when(
        data: (list) {
          if (list.isEmpty) {
            return Center(
              child: Text(
                l10n.noArchivedConversations,
                style: TextStyle(color: tg.textSecondary),
              ),
            );
          }
          return ListView.separated(
            itemCount: list.length,
            separatorBuilder: (_, _) => Padding(
              padding: const EdgeInsets.only(left: 82),
              child: Divider(height: 0.5, color: tg.separator),
            ),
            itemBuilder: (context, i) {
              final entry = list[i];
              return ChatRow(
                entry: entry,
                onOpen: () => openChat(context, entry.ref.key),
              );
            },
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
      ),
    );
  }
}
