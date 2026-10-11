// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Conversations `XmppConnectionService.archiveConversation` /
// `restoreFromArchive` (+ `BookmarkManager.ensureBookmarkIsAutoJoin`).

import 'package:moxxmpp/moxxmpp.dart' show ConferenceBookmark, JID;

import '../account/account_hub.dart';
import '../account/resolve.dart';
import '../platform/app_notifications.dart';
import 'connection.dart';

/// Archives [chatKey] like Conversations overview / menu archive.
///
/// Shared for every chat: clear shade notification, clear draft, mark read,
/// set `archived`. Groups also leave the MUC and turn bookmark `autoJoin` off
/// (when [syncBookmarks] is true). 1:1 chats with a pending incoming
/// subscription reject that request (`stopPresenceUpdatesTo`).
Future<void> archiveConversation(
  String chatKey, {
  bool syncBookmarks = true,
}) async {
  final r = resolveChatKey(chatKey);
  final session = r.session;
  final jid = r.jid;
  final chat = await session.db.getChat(jid);
  if (chat == null) return;

  await AppNotifications.instance.cancelChat(
    accountId: session.account.id,
    chatJid: jid,
  );
  await session.db.setDraft(jid, null);
  await session.db.markChatRead(jid);

  if (chat.isGroup) {
    await _archiveGroup(
      session: session,
      jid: jid,
      syncBookmarks: syncBookmarks,
    );
  } else {
    await _archiveDirect(session: session, jid: jid);
  }

  await session.db.setChatFlag(jid, archived: true);
}

/// Restores [chatKey] like Conversations `restoreFromArchive` when a chat is
/// opened again: clear the archive flag; for groups, ensure bookmark
/// `autoJoin` and rejoin.
Future<void> restoreFromArchive(String chatKey) async {
  final r = resolveChatKey(chatKey);
  final session = r.session;
  final jid = r.jid;
  final chat = await session.db.getChat(jid);
  if (chat == null || !chat.archived) return;

  await session.db.setChatFlag(jid, archived: false);

  if (!chat.isGroup) return;

  final nick = await _ensureBookmarkAutoJoin(session, jid);
  if (nick.isEmpty) return;
  await session.db.upsertChat(jid, isGroup: true, mucNick: nick);
  await session.xmpp.joinGroupChat(jid, nick);
}

Future<void> _archiveGroup({
  required AccountSession session,
  required String jid,
  required bool syncBookmarks,
}) async {
  if (syncBookmarks) {
    final existing = _bookmarkFor(session.xmpp, jid);
    if (existing != null && existing.autoJoin) {
      await session.xmpp.publishConferenceBookmark(
        roomJid: jid,
        name: existing.name,
        nick: existing.nick,
        password: existing.password,
        autoJoin: false,
      );
    }
  }
  await session.xmpp.leaveGroupChat(jid);
  // Clear nick so [groupChatsForJoin] will not rejoin on the next connect
  // (same effect as Conversations bookmark autoJoin=false).
  await session.db.upsertChat(jid, isGroup: true, mucNick: '');
}

Future<void> _archiveDirect({
  required AccountSession session,
  required String jid,
}) async {
  // Conversations: PENDING_SUBSCRIPTION_REQUEST → unsubscribed.
  if (!await session.db.hasIncomingSubscriptionRequest(jid)) return;
  await session.xmpp.rejectSubscription(JID.fromString(jid));
  await session.db.resolveRequest(jid, outgoing: false);
}

/// Conversations `BookmarkManager.ensureBookmarkIsAutoJoin`.
///
/// Returns the nick to join with (bookmark nick, else stored / localpart).
Future<String> _ensureBookmarkAutoJoin(
  AccountSession session,
  String roomJid,
) async {
  final existing = _bookmarkFor(session.xmpp, roomJid);
  final bookmarkNick = existing?.nick?.trim() ?? '';
  final row = await session.db.getChat(roomJid);
  final storedNick = row?.mucNick.trim() ?? '';
  final fallbackNick = session.account.bareJid.split('@').first;
  final joinNick = bookmarkNick.isNotEmpty
      ? bookmarkNick
      : (storedNick.isNotEmpty ? storedNick : fallbackNick);

  await session.xmpp.publishConferenceBookmark(
    roomJid: roomJid,
    name: existing?.name,
    nick: joinNick,
    password: existing?.password,
    autoJoin: true,
  );
  return joinNick;
}

ConferenceBookmark? _bookmarkFor(XmppService xmpp, String roomJid) {
  final bare = JID.fromString(roomJid).toBare().toString();
  for (final b in xmpp.cachedBookmarks) {
    if (JID.fromString(b.jid).toBare().toString() == bare) return b;
  }
  return null;
}
