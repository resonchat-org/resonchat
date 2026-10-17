// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

/// Identifies one conversation under one local account (Conversations
/// `accountUuid` + bare JID).
class ChatRef {
  const ChatRef({required this.accountId, required this.jid});

  final String accountId;
  final String jid;

  /// Opaque route / provider key.
  String get key => '$accountId\x1f$jid';

  static ChatRef? tryParse(Object? raw) {
    if (raw is ChatRef) return raw;
    if (raw is! String || raw.isEmpty) return null;
    final i = raw.indexOf('\x1f');
    if (i <= 0 || i >= raw.length - 1) {
      // Legacy single-account routes passed bare JID only.
      return null;
    }
    return ChatRef(accountId: raw.substring(0, i), jid: raw.substring(i + 1));
  }

  @override
  bool operator ==(Object other) =>
      other is ChatRef && other.accountId == accountId && other.jid == jid;

  @override
  int get hashCode => Object.hash(accountId, jid);

  @override
  String toString() => 'ChatRef($accountId, $jid)';
}
