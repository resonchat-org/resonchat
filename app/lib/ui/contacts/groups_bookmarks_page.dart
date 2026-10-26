// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Full MUC bookmark list (XEP-0402 / legacy). Opened from the single
// "Groups" entry on Contacts — never interleaved with roster rows.

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:resonchat/account/account_hub.dart';
import 'package:resonchat/l10n/l10n.dart';
import 'package:resonchat/state/providers.dart';
import 'package:resonchat/ui/account_filter_overlay.dart';
import 'package:resonchat/ui/account_list_chrome.dart';
import 'package:resonchat/ui/contact_avatar.dart';
import 'package:resonchat/ui/dialog_cell.dart';
import 'package:resonchat/ui/home/open_chat.dart';
import 'package:resonchat/ui/theme.dart';
import 'package:resonchat/xmpp/roster/local_nickname.dart';

class GroupsBookmarksPage extends ConsumerStatefulWidget {
  const GroupsBookmarksPage({super.key, this.initialAccountId});

  /// Display filter carried from Contacts when that tab is already filtered.
  final String? initialAccountId;

  @override
  ConsumerState<GroupsBookmarksPage> createState() =>
      _GroupsBookmarksPageState();
}

class _GroupsBookmarksPageState extends ConsumerState<GroupsBookmarksPage>
    with SingleTickerProviderStateMixin {
  late String? _accountId;
  late final AnimationController _accountPanel;
  late final Animation<Offset> _accountSlide;

  @override
  void initState() {
    super.initState();
    _accountId = widget.initialAccountId;
    _accountPanel = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    );
    _accountSlide = Tween<Offset>(begin: const Offset(-1, 0), end: Offset.zero)
        .animate(
          CurvedAnimation(parent: _accountPanel, curve: Curves.easeOutCubic),
        );
  }

  @override
  void dispose() {
    _accountPanel.dispose();
    super.dispose();
  }

  void _openAccountPanel() => unawaited(_accountPanel.forward());

  void _closeAccountPanel() => unawaited(_accountPanel.reverse());

  List<AccountBookmark> _filter(List<AccountBookmark> list) {
    final id = _accountId;
    if (id == null) return list;
    return list.where((b) => b.account.id == id).toList();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tg = context.tg;
    final hub = ref.watch(accountHubProvider);
    final filterId = _accountId;
    if (filterId != null &&
        !hub.accounts.any((a) => a.id == filterId && a.enabled)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _accountId == filterId) {
          setState(() => _accountId = null);
        }
      });
    }

    final bookmarks = ref.watch(bookmarksProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.groupBookmarks)),
      body: AccountFilterOverlay(
        controller: _accountPanel,
        slide: _accountSlide,
        accounts: hub.accounts,
        selectedAccountId: _accountId,
        onDismiss: _closeAccountPanel,
        onSelected: (id) {
          setState(() => _accountId = id);
          _closeAccountPanel();
        },
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                TgDimens.chatsHorizontalPadding,
                8,
                TgDimens.chatsHorizontalPadding,
                8,
              ),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: AccountFilterMenuButton(onPressed: _openAccountPanel),
              ),
            ),
            Expanded(
              child: bookmarks.when(
                data: (list) {
                  final filtered = _filter(list);
                  if (filtered.isEmpty) {
                    return Center(
                      child: Text(
                        l10n.groupBookmarksEmpty,
                        style: TextStyle(color: tg.textSecondary),
                      ),
                    );
                  }
                  return ListView.separated(
                    itemCount: filtered.length,
                    separatorBuilder: (_, _) => Padding(
                      padding: const EdgeInsets.only(left: 82),
                      child: Divider(height: 0.5, color: tg.separator),
                    ),
                    itemBuilder: (context, i) {
                      return _BookmarkTile(
                        row: filtered[i],
                        colorAccounts: _accountId == null,
                      );
                    },
                  );
                },
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => Center(child: Text('$e')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BookmarkTile extends ConsumerWidget {
  const _BookmarkTile({required this.row, required this.colorAccounts});

  final AccountBookmark row;
  final bool colorAccounts;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tg = context.tg;
    final l10n = context.l10n;
    final multi =
        colorAccounts && ref.watch(accountHubProvider).accounts.length > 1;
    final accent = row.accent;
    final b = row.bookmark;
    final chat = ref.watch(chatProvider(row.ref.key)).value;
    final title = conversationDisplayName(
      storedLocalNickname: chat?.localNickname,
      title: b.displayName,
      jid: b.jid,
      isRoom: true,
    );
    final detail = b.autoJoin ? '${b.jid} · ${l10n.bookmarkAutoJoin}' : b.jid;
    final detailStyle = TextStyle(
      color: tg.textSecondary,
      fontSize: TgDimens.timeFontSize,
      height: 1.15,
    );
    return DialogCell(
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
      onLongPress: () => _confirmRemove(context, ref, title),
      leading: accountAvatarRing(
        show: multi,
        accent: accent,
        child: ContactAvatar(jid: b.jid, title: title),
      ),
      title: title,
      subtitle: Row(
        children: [
          if (multi) ...[
            Flexible(child: accountViaText(row.account.bareJid, accent)),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Text(
              detail,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: detailStyle,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmRemove(
    BuildContext context,
    WidgetRef ref,
    String title,
  ) async {
    final l10n = context.l10n;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.removeBookmark),
        content: Text(l10n.removeBookmarkConfirm(title)),
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
