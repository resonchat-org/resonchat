// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:moxxmpp/moxxmpp.dart' show JID, RosterManager, rosterManager;

import 'package:resonchat/account/account_hub.dart';
import 'package:resonchat/account/chat_ref.dart';
import 'package:resonchat/xmpp/connection.dart';
import 'package:resonchat/xmpp/muc/muc_detect.dart';

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
    this.isMuc = false,
    this.mucJid,
  });

  final String? chatKey;
  final bool invalidJid;

  /// Null when offline / no roster attempt; otherwise roster add success.
  final bool? contactAdded;

  /// Address is a MUC / channel — never add as a roster contact (Conversations
  /// `findOrCreateConversation(..., muc=true)`).
  final bool isMuc;

  /// Bare room JID when [isMuc]; caller should open the join sheet.
  final String? mucJid;
}

/// Chat-list commands (open conversation / add contact).
class ChatsViewModel extends Notifier<void> {
  @override
  void build() {}

  /// Upserts the chat, optionally adds roster + subscription, returns navigation key.
  ///
  /// MUC / public-channel addresses are never written to the roster — that is
  /// how Conversations avoids rooms showing up as contacts.
  Future<OpenChatResult> openChatByJid(String raw) async {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return const OpenChatResult();
    final jid = bareJidOf(trimmed);
    if (jid == null) return const OpenChatResult(invalidJid: true);

    final hub = accountHub;
    final session = hub.primarySession;
    if (session == null) return const OpenChatResult();

    final existing = await session.db.getChat(jid);
    if (existing != null && existing.isGroup) {
      final chatRef = ChatRef(accountId: session.account.id, jid: jid);
      await session.xmpp.removeFromRosterIfPresent(jid);
      return OpenChatResult(chatKey: chatRef.key, isMuc: true, mucJid: jid);
    }

    final xmpp = session.xmpp;
    final online = xmpp.state == XmppConnectionState.connected;
    // Conversations EnterJidDialog: conference.* hosts are channel-shaped.
    // Prefer disco when online; offline, trust the domain hint so we never
    // write a room address into the roster by mistake.
    final isMuc = online
        ? await xmpp.discoSuggestsMuc(jid) || looksLikeChannelJid(jid)
        : looksLikeChannelJid(jid);
    if (isMuc) {
      await xmpp.removeFromRosterIfPresent(jid);
      return OpenChatResult(isMuc: true, mucJid: jid);
    }

    await session.db.upsertChat(jid);
    final chatRef = ChatRef(accountId: session.account.id, jid: jid);

    bool? contactAdded;
    if (online) {
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
