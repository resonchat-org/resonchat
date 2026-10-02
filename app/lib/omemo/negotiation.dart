// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Dual-track negotiation state machine (docs/02 §6). Pure function so the
// core invariant is unit-testable: never emit a message a recipient device
// cannot decrypt.

import 'protocol.dart';

/// Picks the outbound track for one chat.
///
/// - `allDevices`: every recipient device id, **including our own other
///   devices** (Carbons fan-out).
/// - `pqCapable`: devices with a retrievable B-track bundle.
/// - `omemoCapable`: devices supporting standard OMEMO.
///
/// B track only when *all* devices are PQ-capable — **including our own
/// devices**, since a carbon copy we cannot decrypt is a bug. Otherwise
/// the whole message falls back to the A track so mixed chats stay
/// readable. Anything else (unknown devices, empty set) yields
/// [EncMode.none] and the UI must ask instead of sending unreadable
/// ciphertext.
EncMode decideEncMode({
  required Set<int> allDevices,
  required Set<int> pqCapable,
  required Set<int> omemoCapable,
}) {
  if (allDevices.isEmpty) return EncMode.none;

  // Invariant 1 (docs/01 §7): a device we cannot reach by either track
  // blocks sending entirely. Check this first so a PQ-capable set can
  // never mask an OMEMO-incapable device.
  if (!allDevices.every(omemoCapable.contains)) return EncMode.none;

  if (allDevices.every(pqCapable.contains)) return EncMode.pqOmemo;
  return EncMode.standardOmemo;
}
