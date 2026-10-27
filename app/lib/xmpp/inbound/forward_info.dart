// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:moxxmpp/moxxmpp.dart' show JID, UserForwardedData;

import 'package:resonchat/xmpp/chat/forwarding.dart';

/// Displayable XEP-0297 user-forward metadata on an inbound message.
class ForwardInfo {
  const ForwardInfo({
    required this.fromJid,
    required this.author,
    required this.body,
    this.originId = '',
    this.stamp,
  });

  /// Bare JID of the origin conversation (room or peer) for open/join.
  final String fromJid;

  /// Original author nick or bare JID for the forward card.
  final String author;

  /// Inner plaintext body.
  final String body;

  /// MUC room stanza-id for jump (empty unless [type] was groupchat).
  final String originId;

  /// When the forwarder received the original, if stamped.
  final DateTime? stamp;

  /// Null when [data] is missing, encrypted, or has no plaintext body.
  static ForwardInfo? fromUserForwarded(UserForwardedData? data) {
    if (data == null || data.encrypted) return null;
    final body = data.body.trim();
    if (body.isEmpty) return null;
    final from = data.from ?? '';
    final isGroup = (data.type ?? '') == 'groupchat';
    final author = () {
      if (from.isEmpty) return '';
      try {
        final jid = JID.fromString(from);
        if (isGroup && jid.resource.isNotEmpty) {
          return jid.resource;
        }
        return jid.toBare().toString();
      } catch (_) {
        return from;
      }
    }();
    // 1:1 stanza ids are not a shared address for the recipient; only MUC
    // room stanza-ids support jump-to-origin.
    final originId = isGroup ? (data.id?.trim() ?? '') : '';
    return ForwardInfo(
      fromJid: forwardOriginJid(from: data.from, type: data.type),
      author: author,
      body: body,
      originId: originId,
      stamp: data.delay,
    );
  }
}
