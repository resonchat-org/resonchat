// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Deciding which track a message goes out on (docs/10 §4).
//
// The rule this file exists to enforce: the *client* picks the track, and the
// program's only job is to say whether that choice can be carried out. It
// never silently substitutes a different one.
//
// Automatic fallback is not a convenience. Every substitution is a decision
// the user did not make, taken on their behalf, in the one place where
// getting it wrong is silent — the message still goes out, it just goes out
// readable. So:
//   * PQ unavailable      -> do not send. Report, offer OM.
//   * OMEMO unavailable   -> do not send. Report, offer NO.
//   * NO chosen           -> send, having warned.
//
// The last one looks inconsistent. It is not: refusing to send plaintext is
// the client overruling a decision the user was warned about, which is the
// same objection as refusing to send PQ. The difference is that the user
// knows what NO means and chose it anyway, whereas a silent downgrade to NO
// tells them nothing and cannot be consented to.

import '../../l10n/generated/app_localizations.dart';
import '../../xmpp/capabilities.dart';
import 'track.dart';

/// Why a chosen track cannot be used, if it cannot.
///
/// Each case names the alternative worth offering, because "cannot send" on
/// its own leaves the user with nothing to do about it.
enum TrackBlocked {
  /// We could not read the peer's device list, so we know nothing.
  ///
  /// Not the same as "the peer has no devices". Blocking here is what stops
  /// an unreadable capability lookup from being read as permission to send in
  /// the clear.
  unknownPeers,

  /// The peer publishes devices that answer to neither track.
  ///
  /// Invariant 1 (docs/01 §7): a device we cannot reach blocks sending.
  unreachableDevices,

  /// Some recipient device has no usable standard OMEMO bundle.
  standardUnavailable,

  /// The peer publishes no device with a usable PQ bundle.
  pqUnavailable,
}

/// Wording for each blocked case.
///
/// Kept apart from the widgets so the phrasing can be reviewed — and tested —
/// without rendering anything. The subject of every sentence is what happens to
/// the *recipient*, since that is the part the sender cannot see.
extension TrackBlockedMessage on TrackBlocked {
  String get title => switch (this) {
    TrackBlocked.unknownPeers => 'Cannot check what they support',
    TrackBlocked.unreachableDevices => 'They have no reachable device',
    TrackBlocked.standardUnavailable =>
      'Standard encryption is not possible here',
    TrackBlocked.pqUnavailable => 'They cannot read post-quantum messages',
  };

  String get consequence => switch (this) {
    TrackBlocked.unknownPeers =>
      "We could not read this contact's device list, so we do not know "
          'what they can open.',
    TrackBlocked.unreachableDevices =>
      'This contact publishes no encryption device we can encrypt to, so '
          'any message we send would go out readable.',
    TrackBlocked.standardUnavailable =>
      'At least one of their devices has no standard OMEMO bundle, so an '
          'encrypted message would be unreadable on that device.',
    TrackBlocked.pqUnavailable =>
      'None of their devices publish a post-quantum bundle, so a '
          'PQ message would be unreadable on every device they have.',
  };

  /// The line that must not be softened.
  ///
  /// Not "they may not be able to read it" — the concrete consequence, so
  /// there is nothing left for the reader to interpret.
  String get outcome => switch (this) {
    TrackBlocked.unknownPeers =>
      'This message will not be sent until we can tell what they support.',
    TrackBlocked.unreachableDevices =>
      'The only way to send is in the clear, readable by anyone with '
          'access to the server.',
    TrackBlocked.standardUnavailable =>
      'Sending in the clear is the only way this message gets read.',
    TrackBlocked.pqUnavailable =>
      'The other person will not be able to read this message at all.',
  };

  String localizedTitle(AppLocalizations l10n) => switch (this) {
    TrackBlocked.unknownPeers => l10n.trackBlockedUnknownPeersTitle,
    TrackBlocked.unreachableDevices => l10n.trackBlockedUnreachableTitle,
    TrackBlocked.standardUnavailable => l10n.trackBlockedStandardTitle,
    TrackBlocked.pqUnavailable => l10n.trackBlockedPqTitle,
  };

  String localizedConsequence(AppLocalizations l10n) => switch (this) {
    TrackBlocked.unknownPeers => l10n.trackBlockedUnknownPeersConsequence,
    TrackBlocked.unreachableDevices => l10n.trackBlockedUnreachableConsequence,
    TrackBlocked.standardUnavailable => l10n.trackBlockedStandardConsequence,
    TrackBlocked.pqUnavailable => l10n.trackBlockedPqConsequence,
  };

  String localizedOutcome(AppLocalizations l10n) => switch (this) {
    TrackBlocked.unknownPeers => l10n.trackBlockedUnknownPeersOutcome,
    TrackBlocked.unreachableDevices => l10n.trackBlockedUnreachableOutcome,
    TrackBlocked.standardUnavailable => l10n.trackBlockedStandardOutcome,
    TrackBlocked.pqUnavailable => l10n.trackBlockedPqOutcome,
  };
}

/// The outcome of resolving a choice against what the peer supports.
class TrackResolution {
  /// Public because a room's resolution is a genuinely different question and
  /// is answered in muc.dart. The property that matters — that a resolution
  /// never reports a track other than the one requested — is therefore
  /// enforced by tests rather than by visibility, which is the right way round:
  /// a compile error would not have stopped anyone from getting it wrong
  /// inside this file either.
  const TrackResolution({required this.track, required this.blocked});

  /// The track to actually use.
  ///
  /// Always [requested] when [blocked] is null: there is no path here that
  /// returns a track the user did not ask for.
  final Track track;

  /// Null when the choice can be carried out.
  final TrackBlocked? blocked;

  /// True when the message can be sent as chosen.
  bool get canSend => blocked == null;

  /// The track to offer instead, if any.
  ///
  /// Offered as a *suggestion in a dialog the user has to answer*, never
  /// applied on their behalf.
  Track? get alternative => switch (blocked) {
    null => null,
    // Never [Track.none], even where plaintext really is the only way left
    // ([TrackBlocked.unreachableDevices] says so in its own wording). Offering
    // plaintext is a downgrade prompt, and an answer given under pressure is
    // not a decision. MUC holds the same line in its own test.
    TrackBlocked.unknownPeers ||
    TrackBlocked.unreachableDevices ||
    TrackBlocked.standardUnavailable ||
    TrackBlocked.pqUnavailable => Track.standard,
  };
}

/// Resolves a requested track against a capability snapshot.
TrackResolution resolveTrack({
  required Track requested,
  required ChatCapabilities? capabilities,
}) {
  // Plaintext is decided before anything is known about the peer, because it
  // does not depend on what the peer supports. The warning belongs to the UI
  // at the moment of the choice; the transport's job is only to honour it.
  // Blocking here would mean refusing a decision the user was told about and
  // made anyway, which is the same objection as overriding a PQ choice.
  if (requested == Track.none) {
    return const TrackResolution(track: Track.none, blocked: null);
  }

  // No snapshot at all is the same epistemic state as an unreadable one:
  // we know nothing about the peer. Treating "not looked up yet" as "plaintext
  // is fine" is the mistake that turns a slow network into a security hole.
  final caps = capabilities;
  if (caps == null || !caps.reliable) {
    return TrackResolution(
      track: requested,
      blocked: TrackBlocked.unknownPeers,
    );
  }

  // A and B are independent (monocles deviceIds vs omemo2DeviceIds). Do not
  // let an empty classic list block PQ, or an empty PQ list block standard.
  switch (requested) {
    case Track.none:
      return const TrackResolution(track: Track.none, blocked: null);

    case Track.standard:
      if (!caps.classicReliable) {
        return TrackResolution(
          track: requested,
          blocked: TrackBlocked.unknownPeers,
        );
      }
      if (caps.peerDevices.isEmpty) {
        return const TrackResolution(
          track: Track.standard,
          blocked: TrackBlocked.unreachableDevices,
        );
      }
      final allReachable = caps.recipientDevices.every(
        caps.omemoDevices.contains,
      );
      if (allReachable) {
        return const TrackResolution(track: Track.standard, blocked: null);
      }
      return const TrackResolution(
        track: Track.standard,
        blocked: TrackBlocked.standardUnavailable,
      );

    case Track.pq:
      if (!caps.pqReliable) {
        return const TrackResolution(
          track: Track.pq,
          blocked: TrackBlocked.unknownPeers,
        );
      }
      // Non-empty OMEMO2 device list is enough — same as monocles
      // upgradeConversationToOmemo2IfPossible. Bundles are fetched at send.
      if (caps.pqDevices.isNotEmpty) {
        return const TrackResolution(track: Track.pq, blocked: null);
      }
      return const TrackResolution(
        track: Track.pq,
        blocked: TrackBlocked.pqUnavailable,
      );
  }
}
