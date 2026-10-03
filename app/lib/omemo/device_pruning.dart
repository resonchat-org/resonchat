// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Which of our own OMEMO device ids may be removed from our published list.
//
// Why this is a local decision rather than a question about the server: our
// device list gains an entry on every reinstall and nothing ever removed one,
// so a user who has reinstalled a few times accumulates twenty-plus ids whose
// bundles will never answer again. Every one of those entries makes *other
// people's* capability resolution fail — a peer cannot cover a device it cannot
// reach — and the result is that this client stops being able to send to
// anybody, with nothing in the interface explaining why.
//
// The obvious implementation is to ask the server whether each id's bundle
// still exists. That does not work, and the reason is worth writing down: this
// pubsub layer returns the *same* `UnknownPubSubError` for a node that does not
// exist and for a node we failed to read. Since the whole decision hinges on
// "is it gone" versus "could not reach it", a signal that cannot tell them
// apart cannot decide it.
//
// So the candidates come from somewhere we do know: the ids this installation
// has published in the past. An id we published and are no longer using can
// only belong to a build that has been replaced, and device ids are never
// reused, so there is nothing to mistake it for. An id we have never seen is
// left completely alone — it might belong to another of the user's devices, and
// removing it on a guess would downgrade that device's messages to the clear.

/// The ids to keep in [listed].
///
/// [ourDeviceId] is always kept: it was published moments ago, and removing it
/// would make this client invisible to everyone, which is a far worse failure
/// than a stale entry.
///
/// [idsWePublished] is every id this installation has ever put on the list.
/// Only those are candidates; [listed] entries outside it are kept whatever
/// their bundles look like.
///
/// [bundleFetches] answers "did this id's bundle just fetch?". Ids for which it
/// returned false are removed, and only if they are in [idsWePublished].
Set<int> keepableDeviceIds({
  required Set<int> listed,
  required int ourDeviceId,
  required Set<int> idsWePublished,
  required bool Function(int id) bundleFetches,
}) {
  final candidates = idsWePublished.difference({ourDeviceId});
  final kept = <int>{};
  for (final id in listed) {
    if (id == ourDeviceId) {
      kept.add(id);
      continue;
    }
    if (!candidates.contains(id)) {
      // Not ours to judge. Somebody else's device, or a build of ours that we
      // have no record of.
      kept.add(id);
      continue;
    }
    if (bundleFetches(id)) {
      // Still answering. A device that is genuinely in use — another install
      // the user is still running — must keep its entry, or peers stop
      // encrypting to it.
      kept.add(id);
      continue;
    }
    // Our own superseded id whose bundle no longer answers. Nothing can ever
    // read messages addressed to it.
  }
  return kept;
}

/// The ids to remove, i.e. [listed] minus [keepableDeviceIds].
Set<int> deadDeviceIds({
  required Set<int> listed,
  required Set<int> kept,
}) => listed.difference(kept);
