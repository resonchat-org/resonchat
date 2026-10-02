// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The archive.
//
// Without this page, archiving is a one-way door: a conversation leaves the main
// list and there is no way back. A user who archives something to tidy up and
// then wants it again has to reinstall. So the archive is not an extra feature
// here, it is the other half of the archive button.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import 'chat_row.dart';
import 'theme.dart';

class ArchivePage extends ConsumerWidget {
  const ArchivePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tg = context.tg;
    final archived = ref.watch(archivedChatsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Archived')),
      body: archived.when(
        data: (list) {
          if (list.isEmpty) {
            return Center(
              child: Text(
                'Nothing archived',
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
            itemBuilder: (context, i) => Dismissible(
              // Unarchive is the whole point of being on this page, so it is
              // the swipe: the alternative is a row that only exists to be
              // opened and unarchived from inside.
              key: ValueKey('archived-${list[i].jid}'),
              direction: DismissDirection.endToStart,
              background: SwipeBackground(
                alignment: Alignment.centerRight,
                icon: Icons.unarchive_outlined,
                label: 'Restore',
                color: tg.accent,
              ),
              confirmDismiss: (_) async {
                await ref
                    .read(databaseProvider)
                    .setChatFlag(list[i].jid, archived: false);
                return false;
              },
              child: ChatRow(
                chat: list[i],
                onOpen: () => Navigator.of(context)
                    .pushNamed('/chat', arguments: list[i].jid),
              ),
            ),
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
      ),
    );
  }
}