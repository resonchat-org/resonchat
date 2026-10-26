// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:resonchat/account/account_hub.dart';
import 'package:resonchat/account/chat_ref.dart';
import 'package:resonchat/persistence/database.dart';
import 'package:resonchat/xmpp/connection.dart';

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
