// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Shared nick helpers for group transcripts (highlights, labels, colours).

import 'package:flutter/material.dart';

import 'package:resonchat/account/resolve.dart';
import 'package:resonchat/xmpp/muc/muc.dart';

/// Occupant nick from a stored sender (`room@server/nick` or bare nick).
String? occupantNick(String sender) {
  if (sender.isEmpty || sender == 'me') return null;
  final slash = sender.indexOf('/');
  if (slash >= 0 && slash + 1 < sender.length) {
    return sender.substring(slash + 1);
  }
  return sender;
}

/// Nick names that count as "us" for bolding highlights in the transcript.
List<String> highlightNicksFor({
  required String mucNick,
  required String chatKey,
}) {
  final names = <String>{};
  if (mucNick.isNotEmpty) names.add(mucNick);
  try {
    final bare = resolveChatKey(chatKey).session.account.bareJid;
    final at = bare.indexOf('@');
    if (at > 0) names.add(bare.substring(0, at));
  } catch (_) {}
  return names.toList();
}

String? occupantRealJid(GroupChat? room, String nick) {
  if (room == null) return null;
  for (final o in room.occupants) {
    if (o.nick == nick) {
      final jid = o.realJid?.trim();
      if (jid != null && jid.isNotEmpty) return jid;
      return null;
    }
  }
  return null;
}

/// Stable tint for a nick in group transcripts (docs/05).
Color nickColor(String nick) {
  final hue = (nick.hashCode & 0x7fffffff) % 360;
  return HSLColor.fromAHSL(1, hue.toDouble(), 0.55, 0.42).toColor();
}
