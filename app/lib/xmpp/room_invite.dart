// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Incoming MUC invitations (XEP-0045 mediated + XEP-0249 direct).
//
// Conversations folds invites into the chat list and auto-joins; we keep them
// in a pending list so the user can accept or decline explicitly — same inbox
// as presence subscription requests.

import 'dart:async';

import 'package:logging/logging.dart';
import 'package:moxxmpp/moxxmpp.dart';

/// One invitation to join a room.
class RoomInvite {
  const RoomInvite({
    required this.roomJid,
    required this.fromJid,
    this.password = '',
    this.reason = '',
  });

  /// Bare room address (`room@conference.example.org`).
  final String roomJid;

  /// Who invited us (bare), empty when the stanza omitted it.
  final String fromJid;

  final String password;
  final String reason;
}

/// Intercepts invite stanzas before [MessageManager] turns them into bubbles.
class RoomInviteManager extends XmppManagerBase {
  RoomInviteManager() : super(_id);

  static const String _id = 'resonchat.room_invite';

  final _log = Logger('RoomInviteManager');
  final _invites = StreamController<RoomInvite>.broadcast();

  Stream<RoomInvite> get invites => _invites.stream;

  @override
  Future<bool> isSupported() async => true;

  @override
  List<StanzaHandler> getIncomingStanzaHandlers() => [
    StanzaHandler(
      stanzaTag: 'message',
      // Same band as other message extensions: before MessageManager.
      priority: messageExtensionPriority,
      callback: _onMessage,
    ),
  ];

  Future<StanzaHandlerData> _onMessage(
    Stanza message,
    StanzaHandlerData state,
  ) async {
    final invite = parseRoomInvite(message);
    if (invite == null) return state;
    _log.fine(
      'room invite to ${invite.roomJid} from ${invite.fromJid.isEmpty ? "?" : invite.fromJid}',
    );
    if (!_invites.isClosed) _invites.add(invite);
    // Consume: an invite is not a chat message.
    return StanzaHandlerData(true, false, message, state.extensions);
  }
}

/// Parses a mediated (`muc#user`/`invite`) or direct (`jabber:x:conference`)
/// invite from [message], or null when the stanza is something else.
RoomInvite? parseRoomInvite(Stanza message) {
  final from = message.from;
  if (from == null || from.isEmpty) return null;

  // XEP-0045 mediated: <x xmlns='…muc#user'><invite from='…'>…
  final mucUser = message.firstTag('x', xmlns: mucUserXmlns);
  if (mucUser != null) {
    final invite = mucUser.firstTag('invite');
    if (invite != null) {
      final roomJid = JID.fromString(from).toBare().toString();
      final inviterRaw = invite.attributes['from'];
      final inviter = inviterRaw is String && inviterRaw.isNotEmpty
          ? JID.fromString(inviterRaw).toBare().toString()
          : '';
      final reason = invite.firstTag('reason')?.innerText() ?? '';
      final password = mucUser.firstTag('password')?.innerText() ?? '';
      return RoomInvite(
        roomJid: roomJid,
        fromJid: inviter,
        password: password,
        reason: reason,
      );
    }
  }

  // XEP-0249 direct: <x xmlns='jabber:x:conference' jid='room@…'/>
  const directNs = 'jabber:x:conference';
  final direct = message.firstTag('x', xmlns: directNs);
  if (direct != null) {
    final roomRaw = direct.attributes['jid'];
    if (roomRaw is! String || roomRaw.isEmpty) return null;
    final roomJid = JID.fromString(roomRaw).toBare().toString();
    final inviter = JID.fromString(from).toBare().toString();
    final password = (direct.attributes['password'] as String?) ?? '';
    final reason = (direct.attributes['reason'] as String?) ?? '';
    return RoomInvite(
      roomJid: roomJid,
      fromJid: inviter,
      password: password,
      reason: reason,
    );
  }

  return null;
}
