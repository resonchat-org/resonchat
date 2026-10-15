// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Contacts-tab commands that are not pure UI: open a bookmark room, add a
// bare JID (delegates to [ChatsViewModel.openChatByJid]).

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../account/account_hub.dart';
import '../chats/chats_viewmodel.dart';

export '../chats/chats_viewmodel.dart' show OpenChatResult;

/// Contacts-tab side effects (add contact / open group bookmark).
class ContactsViewModel extends Notifier<void> {
  @override
  void build() {}

  /// Roster + subscription for a typed bare JID (same path as chat-list add).
  Future<OpenChatResult> addContactByJid(String raw) {
    return ref.read(chatsViewModelProvider.notifier).openChatByJid(raw);
  }

  /// Ensures a 1:1 chat row exists for [row], then returns its [ChatRef] key.
  ///
  /// Search/idle roster tiles used to call [openChat] alone; contacts added
  /// after bootstrap often have no chats row yet, so the conversation never
  /// appeared. Empty chats are fine — [upsertChat] seeds activity at epoch.
  Future<String?> openContact(AccountContact row) async {
    final session = accountHub.session(row.account.id);
    if (session == null) return null;
    final jid = row.entry.jid;
    final name = row.entry.name.trim();
    await session.db.upsertChat(
      jid,
      title: name.isNotEmpty ? name : null,
      isGroup: false,
    );
    final existing = await session.db.getChat(jid);
    if (existing != null && existing.archived) {
      await session.db.setChatFlag(jid, archived: false);
    }
    return row.ref.key;
  }

  /// Ensures a local group chat row exists, then returns its [ChatRef] key.
  Future<String?> openBookmark(AccountBookmark row) async {
    final b = row.bookmark;
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
    return row.ref.key;
  }
}

final contactsViewModelProvider = NotifierProvider<ContactsViewModel, void>(
  ContactsViewModel.new,
);
