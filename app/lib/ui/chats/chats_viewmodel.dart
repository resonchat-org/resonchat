// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:moxxmpp/moxxmpp.dart' show JID, RosterManager, rosterManager;

import '../../account/account_hub.dart';
import '../../account/chat_ref.dart';
import '../../xmpp/connection.dart';

/// Reduces whatever the user typed to a bare JID, or null if it is not one.
///
/// `user@example.org/phone` and `user@example.org` are the same contact for
/// roster purposes; only the bare form belongs in the roster.
String? bareJidOf(String raw) {
  final trimmed = raw.trim();
  final slash = trimmed.indexOf('/');
  final bare = slash == -1 ? trimmed : trimmed.substring(0, slash);
  final parts = bare.split('@');
  if (parts.length != 2 || parts[0].isEmpty || parts[1].isEmpty) return null;
  if (parts[1].contains(' ')) return null;
  return bare;
}

/// Outcome of opening a chat from the roster bar.
class OpenChatResult {
  const OpenChatResult({
    this.chatKey,
    this.invalidJid = false,
    this.contactAdded,
  });

  final String? chatKey;
  final bool invalidJid;

  /// Null when offline / no roster attempt; otherwise roster add success.
  final bool? contactAdded;
}

/// Chat-list commands (open conversation / add contact).
class ChatsViewModel extends Notifier<void> {
  @override
  void build() {}

  /// Upserts the chat, optionally adds roster + subscription, returns navigation key.
  Future<OpenChatResult> openChatByJid(String raw) async {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return const OpenChatResult();
    final jid = bareJidOf(trimmed);
    if (jid == null) return const OpenChatResult(invalidJid: true);

    final hub = accountHub;
    final session = hub.primarySession;
    if (session == null) return const OpenChatResult();

    await session.db.upsertChat(jid);
    final chatRef = ChatRef(accountId: session.account.id, jid: jid);

    bool? contactAdded;
    final xmpp = session.xmpp;
    if (xmpp.state == XmppConnectionState.connected) {
      final roster = xmpp.connection?.getManagerById<RosterManager>(
        rosterManager,
      );
      final added = await roster?.addToRoster(jid, jid) ?? false;
      contactAdded = added;
      if (added) {
        await xmpp.requestSubscription(JID.fromString(jid));
        await xmpp.subscribePeerPep(JID.fromString(jid));
      }
    }

    return OpenChatResult(chatKey: chatRef.key, contactAdded: contactAdded);
  }
}

final chatsViewModelProvider = NotifierProvider<ChatsViewModel, void>(
  ChatsViewModel.new,
);
