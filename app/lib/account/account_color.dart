// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Stable accent per local account (Conversations / XEP-0392 style).
// Used for chat-list chrome that answers "which of *my* accounts owns this
// row" — not for contact names or message bubbles.

import 'package:flutter/material.dart';

/// Deterministic vivid color from [accountBareJid].
Color accountAccent(String accountBareJid) {
  final key = accountBareJid.trim().toLowerCase();
  if (key.isEmpty) return const Color(0xFF3D9BD4);
  // FNV-1a 32-bit — stable across runs, independent of Theme.
  var hash = 0x811c9dc5;
  for (final u in key.codeUnits) {
    hash ^= u;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  final hue = (hash % 360).toDouble();
  return HSLColor.fromAHSL(1, hue, 0.55, 0.48).toColor();
}

/// Short label for list rows (`alice@ex.com` → `alice@ex.com`, long → truncate).
String accountViaLabel(String accountBareJid, {int maxLen = 28}) {
  final jid = accountBareJid.trim();
  if (jid.length <= maxLen) return jid;
  final at = jid.indexOf('@');
  if (at <= 0) return '${jid.substring(0, maxLen - 1)}…';
  final local = jid.substring(0, at);
  final domain = jid.substring(at + 1);
  if (local.length + 1 + domain.length <= maxLen) return jid;
  final keepLocal = (maxLen - domain.length - 2).clamp(1, local.length);
  return '${local.substring(0, keepLocal)}…@$domain';
}
