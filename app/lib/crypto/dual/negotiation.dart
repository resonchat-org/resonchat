// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Dual-track negotiation state machine (docs/02 §6). Pure function so the
// core invariant is unit-testable: never emit a message a recipient device
// cannot decrypt.

/// Per-chat encryption mode (docs/02 §6).
enum EncMode {
  /// Cannot encrypt to all devices (or no devices known).
  none,

  /// Standard OMEMO interop track (Conversations / legacy).
  standardOmemo,

  /// monocles PQ-OMEMO2 track.
  pqOmemo,
}

/// Short UI label for [mode], without emoji (icons draw the lock).
String encModeLabel(EncMode mode) => switch (mode) {
  EncMode.pqOmemo => 'OMEMO2',
  EncMode.standardOmemo => 'OMEMO',
  EncMode.none => 'Unencrypted',
};

/// Picks the outbound track for one chat.
///
/// - `allDevices`: every recipient device id, **including our own other
///   devices** (Carbons fan-out).
/// - `pqCapable`: devices with a retrievable B-track bundle.
/// - `omemoCapable`: devices supporting standard OMEMO.
///
/// A device counts as reachable when it is on *either* track. Auto mode
/// still prefers B only when every device is PQ-capable (including our
/// own), otherwise A so mixed chats stay readable. A device on neither
/// track yields [EncMode.none].
EncMode decideEncMode({
  required Set<int> allDevices,
  required Set<int> pqCapable,
  required Set<int> omemoCapable,
}) {
  if (allDevices.isEmpty) return EncMode.none;

  // Invariant 1 (docs/01 §7): unreachable by both tracks blocks sending.
  // PQ-only devices (no usable classic bundle) are still reachable on B.
  if (!allDevices.every(
    (d) => omemoCapable.contains(d) || pqCapable.contains(d),
  )) {
    return EncMode.none;
  }

  if (allDevices.every(pqCapable.contains)) return EncMode.pqOmemo;
  return EncMode.standardOmemo;
}
