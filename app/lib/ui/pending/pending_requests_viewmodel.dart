// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Answer a contact subscription or a room invitation. The page keeps the
// nickname dialog and opens the chat after a successful join.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:moxxmpp/moxxmpp.dart' show JID;

import 'package:resonchat/account/account_hub.dart';
import 'package:resonchat/account/chat_ref.dart';
import 'package:resonchat/persistence/database.dart';
import 'package:resonchat/state/providers.dart';
import 'package:resonchat/xmpp/muc.dart';

/// [chatKey] is set when the room was joined. [reason] is the join failure.
class AcceptInviteResult {
  const AcceptInviteResult.joined(this.chatKey) : reason = null;

  const AcceptInviteResult.failed(this.reason) : chatKey = null;

  final String? chatKey;
  final String? reason;
}

final pendingRequestsViewModelProvider =
    NotifierProvider<PendingRequestsViewModel, void>(
      PendingRequestsViewModel.new,
    );

class PendingRequestsViewModel extends Notifier<void> {
  @override
  void build() {}

  Future<void> cancelOutgoing(String bareJid) async {
    ref
        .read(xmppServiceProvider)
        .resolveOutgoingRequest(JID.fromString(bareJid));
    await ref.read(databaseProvider).resolveRequest(bareJid, outgoing: true);
  }

  Future<void> answerSubscription(
    String bareJid, {
    required bool accept,
  }) async {
    final jid = JID.fromString(bareJid);
    final xmpp = ref.read(xmppServiceProvider);
    if (accept) {
      await xmpp.acceptSubscription(jid);
    } else {
      await xmpp.rejectSubscription(jid);
    }
    xmpp.resolveIncomingRequest(jid);
    await ref.read(databaseProvider).resolveRequest(bareJid, outgoing: false);
  }

  Future<void> declineInvite(RoomInvitation invite) async {
    await ref
        .read(xmppServiceProvider)
        .declineRoomInvite(roomJid: invite.roomJid, toInviter: invite.fromJid);
    await ref.read(databaseProvider).removeRoomInvitation(invite.roomJid);
  }

  Future<AcceptInviteResult> acceptInvite(
    RoomInvitation invite, {
    required String nick,
  }) async {
    final xmpp = ref.read(xmppServiceProvider);
    final failure = await xmpp.joinGroupChat(invite.roomJid, nick);
    if (failure != null) {
      return AcceptInviteResult.failed('$failure');
    }
    final db = ref.read(databaseProvider);
    final features = await xmpp.queryRoomFeatures(invite.roomJid);
    final encryptable = isPrivateAndNonAnonymous(features);
    await xmpp.refreshRoomMembership(
      invite.roomJid,
      privateNonAnonymous: encryptable,
      nonAnonymous: isNonAnonymousRoom(features),
    );
    await db.upsertChat(
      invite.roomJid,
      isGroup: true,
      mucNick: nick,
      title: invite.roomJid,
      mucPrivateNonAnonymous: encryptable,
    );
    await xmpp.removeFromRosterIfPresent(invite.roomJid);
    unawaited(
      xmpp.publishConferenceBookmark(roomJid: invite.roomJid, nick: nick),
    );
    await db.removeRoomInvitation(invite.roomJid);
    final accountId = accountHub.primarySession?.account.id;
    final chatKey = accountId == null
        ? invite.roomJid
        : ChatRef(accountId: accountId, jid: invite.roomJid).key;
    return AcceptInviteResult.joined(chatKey);
  }
}
