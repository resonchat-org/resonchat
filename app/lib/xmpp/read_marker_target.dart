// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Routing for XEP-0333 `<displayed/>` markers.

/// Where a read marker's bookkeeping belongs.
enum ReadMarkerTarget {
  /// A 1:1 message: mark the outgoing rows in the bare-JID chat displayed.
  direct,

  /// A room message: resolve the occupant's real JID and record one reader.
  room,
}

/// Picks the bookkeeping path for a marker whose chat row is known.
///
/// A 1:1 peer may attach a resource (Gajim always does), so a full JID alone
/// does not make a marker a room marker. Only an actual group chat row may
/// take the occupant path; a missing row cannot be a room we have joined.
ReadMarkerTarget readMarkerTarget({required bool? chatIsGroup}) =>
    (chatIsGroup ?? false) ? ReadMarkerTarget.room : ReadMarkerTarget.direct;
