// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Distinguish MUC / channel addresses from roster contacts.
//
// Conversations' EnterJidDialog refuses (or warns on) conference-looking
// domains before adding a roster contact; ChannelDiscovery always opens with
// MODE_MULTI. Rooms must never land on the roster as contacts.

/// Domain labels that usually host XEP-0045 rooms (Conversations
/// `EnterJidDialog.SUSPICIOUS_DOMAINS`).
const suspiciousMucDomainLabels = <String>{
  'conference',
  'muc',
  'room',
  'rooms',
  'chat',
};

/// True when [domain] looks like a MUC service host (`conference.example.org`).
///
/// Matches Conversations `suspiciousSubDomain`: at least three labels and the
/// leftmost one is a known conference marker. Used only as a hint before disco
/// — never as sole proof that an address is a room.
bool looksLikeChannelDomain(String domain) {
  final parts = domain.toLowerCase().split('.');
  return parts.length >= 3 && suspiciousMucDomainLabels.contains(parts.first);
}

/// Bare JID whose domain looks like a channel host.
bool looksLikeChannelJid(String bareJid) {
  final at = bareJid.lastIndexOf('@');
  if (at <= 0 || at >= bareJid.length - 1) return false;
  return looksLikeChannelDomain(bareJid.substring(at + 1));
}
