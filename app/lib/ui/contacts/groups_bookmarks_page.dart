// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Full MUC bookmark list (XEP-0402 / legacy). Opened from the single
// "Groups" entry on Contacts — never interleaved with roster rows.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../account/account_hub.dart';
import '../../l10n/l10n.dart';
import '../../state/providers.dart';
import '../contact_avatar.dart';
import '../home/open_chat.dart';
import '../room/create_group_sheet.dart';
import '../theme.dart';

class GroupsBookmarksPage extends ConsumerWidget {
  const GroupsBookmarksPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final tg = context.tg;
    final bookmarks = ref.watch(bookmarksProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.groupBookmarks),
        actions: [
          IconButton(
            icon: const Icon(Icons.group_add_outlined),
            tooltip: l10n.joinGroup,
            onPressed: () => unawaited(showGroupActionsSheet(context)),
          ),
        ],
      ),
      body: bookmarks.when(
        data: (list) {
          if (list.isEmpty) {
            return Center(
              child: Text(
                l10n.groupBookmarksEmpty,
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
              final row = list[i];
              return _BookmarkTile(row: row);
            },
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
      ),
    );
  }
}

class _BookmarkTile extends ConsumerWidget {
  const _BookmarkTile({required this.row});

  final AccountBookmark row;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tg = context.tg;
    final l10n = context.l10n;
    final b = row.bookmark;
    return ListTile(
      leading: ContactAvatar(jid: b.jid, title: b.displayName, radius: 22),
      title: Text(b.displayName, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        b.autoJoin ? '${b.jid} · ${l10n.bookmarkAutoJoin}' : b.jid,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: tg.textSecondary,
          fontSize: TgDimens.timeFontSize,
        ),
      ),
      onTap: () async {
        final session = accountHub.session(row.account.id);
        if (session != null) {
          final nick = (b.nick != null && b.nick!.trim().isNotEmpty)
              ? b.nick!.trim()
              : row.account.bareJid.split('@').first;
          final bookmarkName = b.name?.trim();
          await session.db.upsertChat(
            b.jid,
            title: (bookmarkName != null && bookmarkName.isNotEmpty)
                ? bookmarkName
                : null,
            isGroup: true,
            mucNick: nick,
          );
        }
        if (!context.mounted) return;
        openChat(context, row.ref.key);
      },
      onLongPress: () => _confirmRemove(context, ref),
    );
  }

  Future<void> _confirmRemove(BuildContext context, WidgetRef ref) async {
    final l10n = context.l10n;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.removeBookmark),
        content: Text(l10n.removeBookmarkConfirm(row.bookmark.displayName)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.removeBookmark),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final session = accountHub.session(row.account.id);
    await session?.xmpp.retractConferenceBookmark(row.bookmark.jid);
  }
}
