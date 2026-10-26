// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Noticing that a contact's capabilities changed, without acting on it
// (docs/10 §8).
//
// The rule: **never change the setting.** A client's messages silently
// switching between PO and OM for the same person looks like a bug, and the
// user has no way to tell whether their choice was overridden or the other
// party changed. So this only ever produces a piece of advice, and the UI
// decides when to show it.
//
// Two directions, handled differently on purpose:
//
//   * Up   — PQ became possible. Worth a quiet, dismissible banner. The user
//            asked for OM and OM works; nothing is broken.
//   * Down — a device disappeared. Not quiet: the chosen track may now
//            produce nothing at all, which is the one case where a hint that
//            can be missed turns into a message the user believes was sent.

import 'package:resonchat/crypto/dual/track.dart';
import 'package:resonchat/crypto/dual/track_resolver.dart';
import 'package:resonchat/xmpp/encryption/capabilities.dart';

/// Why the advice exists.
enum TrackAdviceKind {
  /// The post-quantum track became reachable (at least one peer device).
  pqNowPossible,

  /// A device was lost, so the chosen track can no longer be used.
  chosenTrackBlocked,
}

/// One piece of advice about a conversation.
class TrackAdvice {
  const TrackAdvice({
    required this.chatJid,
    required this.kind,
    required this.track,
    required this.blocked,
  });

  /// Which conversation this is about.
  ///
  /// Carried rather than inferred from "whoever has the page open": a banner
  /// about one contact's devices appearing above another contact's messages
  /// is worse than no banner.
  final String chatJid;

  final TrackAdviceKind kind;

  /// The track the user has chosen, which is what the advice is about.
  final Track track;

  /// Null unless [kind] is [TrackAdviceKind.chosenTrackBlocked].
  final TrackBlocked? blocked;

  /// A single line, safe to put in a banner.
  String get message => switch (kind) {
    TrackAdviceKind.pqNowPossible =>
      'Post-quantum is now possible here — only ResonChat apps can read it.',
    TrackAdviceKind.chosenTrackBlocked =>
      '${blocked?.consequence ?? 'This contact can no longer be reached.'} '
          'Messages on ${track.label} will ask you what to do.',
  };

  /// The track worth offering instead.
  ///
  /// Never [Track.none]: "send it in the clear" is not a remedy for a device
  /// that went away, and offering it here is how a capability change turns
  /// into a downgrade the user accepts without reading.
  Track get suggestion => switch (kind) {
    TrackAdviceKind.pqNowPossible => Track.pq,
    TrackAdviceKind.chosenTrackBlocked =>
      resolveTrack(requested: track, capabilities: null).alternative ??
          Track.standard,
  };
}

/// True when every classic recipient id also appears on the OMEMO2 list.
///
/// Optional "full coverage" hint only — not the send gate. Empty classic
/// list is false (vacuous every() must not claim protection).
bool everyDeviceIsPq(ChatCapabilities caps) {
  if (!caps.pqReliable) return false;
  if (caps.recipientDevices.isEmpty) return false;
  return caps.recipientDevices.every(caps.pqDevices.contains);
}

/// True when the peer publishes at least one OMEMO2 device id.
///
/// Independent of the classic list — [ChatCapabilities.pqDevices] is B-only.
bool anyPeerDeviceIsPq(ChatCapabilities caps) {
  if (!caps.pqReliable) return false;
  return caps.pqDevices.isNotEmpty;
}

/// Compares two snapshots of the same conversation.
///
/// Returns null when there is nothing worth interrupting the user for. Both
/// snapshots being unreliable is the most important of those cases: an
/// unreadable device list is not evidence of anything, in either direction,
/// and treating a failed bundle fetch as "a device vanished" would train the
/// user to dismiss these.
TrackAdvice? compareCapabilities({
  required String chatJid,
  required Track chosen,
  required ChatCapabilities previous,
  required ChatCapabilities current,
}) {
  if (!previous.reliable || !current.reliable) return null;

  if (!anyPeerDeviceIsPq(previous) && anyPeerDeviceIsPq(current)) {
    return TrackAdvice(
      chatJid: chatJid,
      kind: TrackAdviceKind.pqNowPossible,
      track: chosen,
      blocked: null,
    );
  }

  // Downgrade. Only worth saying when it actually breaks the chosen track:
  // a device disappearing while the user is on OM and OM still works is not
  // something to interrupt them for.
  final now = resolveTrack(requested: chosen, capabilities: current);
  final before = resolveTrack(requested: chosen, capabilities: previous);
  if (before.canSend && !now.canSend) {
    return TrackAdvice(
      chatJid: chatJid,
      kind: TrackAdviceKind.chosenTrackBlocked,
      track: chosen,
      blocked: now.blocked,
    );
  }

  return null;
}
