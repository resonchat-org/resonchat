// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Which OMEMO device ids may be removed from a published device list.
//
// The problem this exists for: our device list gains an entry on every
// reinstall and nothing ever removed one, so a user who has reinstalled a few
// times accumulates twenty-plus ids whose bundles will never answer again. Every
// one of those entries makes *other people's* capability resolution fail — a
// peer cannot cover a device it cannot reach — and the result is that this
// client stops being able to send to anybody, with nothing in the interface
// explaining why.
//
// The decision turns on one distinction: "the bundle is gone" versus "I could
// not reach the bundle right now". Getting it wrong in the permissive direction
// deletes a live device and silently downgrades somebody's messages to the
// clear; getting it wrong in the strict direction leaves a stale entry that
// blocks sending. So the asymmetry is deliberate and is the whole reason this
// is a separate file with its own tests.

/// The ids to keep in [listed].
///
/// [ourDeviceId] is always kept: it was published moments ago, and removing it
/// would make this client invisible to everyone — a far worse failure than a
/// stale entry.
///
/// [bundleAbsent] must answer only from evidence that the bundle is *not there*.
/// A network failure, a rate limit, or a server that did not answer must return
/// false, because "I could not reach it" is not "it is gone". That contract is
/// the caller's to honour, and the second parameter is what makes it possible:
/// [knownGone] exists for callers that can only narrow the candidate set
/// themselves.
Set<int> keepableDeviceIds({
  required Set<int> listed,
  required int ourDeviceId,
  required bool Function(int id) bundleAbsent,
}) {
  final kept = <int>{};
  for (final id in listed) {
    if (id == ourDeviceId) {
      kept.add(id);
      continue;
    }
    if (!bundleAbsent(id)) {
      kept.add(id);
      continue;
    }
    // Positively established as gone. Nothing can ever read a message addressed
    // to this id again, so leaving it on the list only makes peers fail.
  }
  return kept;
}

/// The ids to remove, i.e. [listed] minus the ones kept.
///
/// Separate from [keepableDeviceIds] so the caller can report what changed, and
/// so "nothing was removed" is distinguishable from "the list was never read".
Set<int> deadDeviceIds({required Set<int> listed, required Set<int> kept}) =>
    listed.difference(kept);
