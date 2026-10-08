// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import '../store/database.dart';
import '../xmpp/connection.dart';
import 'account_hub.dart';
import 'chat_ref.dart';

/// Resolves a provider/route key to the owning session and bare chat JID.
({AccountSession session, String jid}) resolveChatKey(String key) {
  final ref = ChatRef.tryParse(key);
  if (ref != null) {
    final s = accountHub.session(ref.accountId);
    if (s == null) {
      throw StateError('unknown account ${ref.accountId}');
    }
    return (session: s, jid: ref.jid);
  }
  final s = accountHub.primarySession;
  if (s == null) throw StateError('no account session');
  return (session: s, jid: key);
}

AppDatabase dbForChatKey(String key) => resolveChatKey(key).session.db;

XmppService xmppForChatKey(String key) => resolveChatKey(key).session.xmpp;
