// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The three tracks a message can travel on, and how each is shown.
//
// A message's label must reflect the track it *actually* used, never the one
// that was merely intended. Keeping that rule in one place is what stops the
// worst possible outcome: a bubble marked `PO` that was actually sent as
// standard OMEMO, or worse, as plaintext.
//
// See docs/10-track-selection.md.

import 'package:flutter/material.dart';

import 'package:moxxmpp/moxxmpp.dart'
    show ExplicitEncryptionType, emeOmemo, emePomemo0;

import 'package:resonchat/crypto/dual/fingerprint_trust.dart';
import 'package:resonchat/l10n/generated/app_localizations.dart';

/// Which track a message used.
///
/// The [name] of each value is the token stored in `messages.enc_mode`; the
/// constructor arguments are what the user sees. Keeping the storage token
/// separate from the display text means neither can drift into the other.
enum Track {
  /// Plaintext. Anyone with access to the server's storage can read it.
  none(label: 'NO', icon: Icons.close),

  /// XEP-0384 standard OMEMO. Interoperable with other clients.
  standard(label: 'OM', icon: Icons.shield_outlined),

  /// monocles PQ-OMEMO2 track (`urn:monocles:omemo-pq:1`).
  pq(label: 'O2', icon: Icons.shield);

  const Track({required this.label, required this.icon});

  /// Two-letter code shown under the message.
  final String label;

  /// Semantic icon; never an emoji, which renders differently per platform
  /// and cannot be styled.
  final IconData icon;

  /// The EME namespace declared for this track (XEP-0380).
  String? get emeNamespace => switch (this) {
    Track.none => null,
    Track.standard => emeOmemo,
    Track.pq => emePomemo0,
  };

  /// Human-readable label for the track picker (English; tests / logs).
  String get description => switch (this) {
    Track.none =>
      'Plaintext — anyone with access to the server can read '
          'this.',
    Track.standard =>
      'Standard OMEMO — readable by other XMPP apps such as Conversations.',
    Track.pq => 'PQ OMEMO2 — post-quantum, interoperable with monocles.',
  };

  /// Localized description for UI.
  String localizedDescription(AppLocalizations l10n) => switch (this) {
    Track.none => l10n.trackDescriptionNone,
    Track.standard => l10n.trackDescriptionStandard,
    Track.pq => l10n.trackDescriptionPq,
  };

  /// Leading phrase of [localizedDescription] (before the em dash), for
  /// compact UI such as the chat AppBar subtitle.
  String localizedShortLabel(AppLocalizations l10n) {
    final full = localizedDescription(l10n);
    final i = full.indexOf('—');
    return i > 0 ? full.substring(0, i).trim() : full;
  }

  /// Recovers the track from a received EME declaration.
  ///
  /// Null when the message carried no `<encryption/>` element, which means
  /// plaintext — the only honest reading, since a sender that omits EME has
  /// not claimed encryption.
  static Track? fromEme(ExplicitEncryptionType? type) => switch (type) {
    null => Track.none,
    ExplicitEncryptionType.pomemo0 => Track.pq,
    // `omemo` is the namespace Conversations and Signal actually send;
    // `omemo1`/`omemo2` are the XEP-0384 spellings.
    ExplicitEncryptionType.omemo ||
    ExplicitEncryptionType.omemo1 ||
    ExplicitEncryptionType.omemo2 => Track.standard,
    // OTR, OpenPGP and anything unknown land here. They are encrypted,
    // just not by us, and we cannot read them — which the caller signals
    // separately as a decryption failure rather than a track.
    _ => null,
  };

  /// True when [type] is an encryption namespace we do not implement.
  static bool isForeignEncryption(ExplicitEncryptionType? type) =>
      switch (type) {
        null => false,
        ExplicitEncryptionType.otr ||
        ExplicitEncryptionType.legacyOpenPGP ||
        ExplicitEncryptionType.openPGP ||
        ExplicitEncryptionType.unknown => true,
        _ => false,
      };

  /// The token written to `chats.track_override` and to the global default.
  ///
  /// Exactly [label], so a stored value is what the user would have read off
  /// the screen. A hand-edited or restored database stays debuggable, and the
  /// two cannot drift apart because there is only one string.
  String get stored => label;

  /// Recovers a track from a stored token.
  ///
  /// Null for anything unrecognised, and the caller decides what to do. The
  /// safe default is the standard track rather than plaintext: silently
  /// downgrading a stored choice to "no encryption" would send messages in
  /// the clear because of a typo.
  static Track? fromStored(String value) => switch (value.toLowerCase()) {
    'o2' || 'po' || 'pq' || 'pqomemo' || 'omemo2' => Track.pq,
    'om' || 'standard' || 'standardomemo' => Track.standard,
    'no' || 'none' => Track.none,
    _ => null,
  };
}

/// The token stored in `messages.enc_mode`.
///
/// Wire: [Track.stored], optional `:{trust}` (`om:verified`, `o2:blind`, …).
/// Bubble text is always NO/OM/O2; [icon] carries trust (Gajim-style).
class EncModeToken {
  const EncModeToken._(this.track, [this.trust]);

  static const none = EncModeToken._(Track.none);
  static const standard = EncModeToken._(Track.standard);
  static const pq = EncModeToken._(Track.pq);
  static const error = EncModeToken._(null);

  /// The track this token records, or null for [error].
  final Track? track;

  /// Snapshot of fingerprint trust when the message was stored, if known.
  final FingerprintTrust? trust;

  /// Wire form written to SQL.
  String get wire {
    if (track == null) return 'error';
    if (track == Track.none) return track!.stored;
    final base = track!.stored;
    final t = trust;
    if (t == null) return base;
    return '$base:${t.wire}';
  }

  /// Short label under the bubble: always `NO` / `OM` / `O2` / `ERR`.
  ///
  /// Trust is carried by [icon] (one glyph), not by a text suffix — a
  /// trailing `✓`/`?` next to a separate icon reads as two indicators.
  String get label {
    if (track == null) return 'ERR';
    return track!.label;
  }

  /// Display trust for an encrypted token. Missing snapshot → undecided so
  /// the bubble never looks the same as blindly trusted.
  FingerprintTrust? get displayTrust {
    if (track == null || track == Track.none) return null;
    return trust ?? FingerprintTrust.undecided;
  }

  /// One glyph: outline = standard OMEMO (OM), filled = PQ OMEMO2 (O2);
  /// shape family = Verified / Blind / Untrusted|Undecided.
  ///
  /// Seven readable states without relying on colour alone.
  IconData get icon {
    if (track == null) return Icons.error_outline;
    if (track == Track.none) return Icons.lock_open;
    final om = track == Track.standard;
    return switch (displayTrust!) {
      FingerprintTrust.verified =>
        om ? Icons.verified_user_outlined : Icons.verified_user,
      FingerprintTrust.blind => om ? Icons.shield_outlined : Icons.shield,
      FingerprintTrust.undecided || FingerprintTrust.untrusted =>
        om ? Icons.remove_moderator_outlined : Icons.remove_moderator,
    };
  }

  /// Plaintext, or encryption the user has not accepted (undecided /
  /// untrusted / unknown snapshot).
  bool get emphasizeWarning {
    if (track == null || track == Track.none) return true;
    final t = displayTrust;
    return t == FingerprintTrust.untrusted || t == FingerprintTrust.undecided;
  }

  /// Tooltip: track short name + trust label (aligned with Security page).
  String tooltip(AppLocalizations l10n) {
    if (track == null) return l10n.unableToDecrypt;
    if (track == Track.none) {
      return track!.localizedShortLabel(l10n);
    }
    final trustLabel = switch (displayTrust!) {
      FingerprintTrust.verified => l10n.fingerprintTrustVerified,
      FingerprintTrust.blind => l10n.fingerprintTrustBlind,
      FingerprintTrust.undecided => l10n.fingerprintTrustUndecided,
      FingerprintTrust.untrusted => l10n.fingerprintTrustUntrusted,
    };
    return '${track!.localizedShortLabel(l10n)} — $trustLabel';
  }

  /// The token for [track], optionally with a trust snapshot.
  static EncModeToken of(Track track, {FingerprintTrust? trust}) {
    if (track == Track.none || trust == null) {
      return switch (track) {
        Track.none => EncModeToken.none,
        Track.standard => EncModeToken.standard,
        Track.pq => EncModeToken.pq,
      };
    }
    return EncModeToken._(track, trust);
  }

  /// Gajim `encrypt_message`: outgoing OMEMO is always VERIFIED.
  static EncModeToken forOutgoing(Track track) {
    if (track == Track.none) return EncModeToken.none;
    return EncModeToken.of(track, trust: FingerprintTrust.verified);
  }

  /// Badge for a stored row. History is not rewritten when trust changes
  /// (Gajim). Legacy own rows without a trust suffix → Verified.
  static EncModeToken forBubble(String wire, {required bool incoming}) {
    final parsed = EncModeToken.parse(wire);
    if (!incoming &&
        parsed.track != null &&
        parsed.track != Track.none &&
        parsed.trust == null) {
      return EncModeToken.forOutgoing(parsed.track!);
    }
    return parsed;
  }

  /// Reads a stored value, including every spelling earlier builds wrote.
  static EncModeToken parse(String? value) {
    if (value == null || value.isEmpty) return EncModeToken.none;
    final raw = value.toLowerCase();
    if (raw == 'error') return EncModeToken.error;

    FingerprintTrust? trust;
    var trackPart = raw;
    final colon = raw.indexOf(':');
    if (colon > 0) {
      trackPart = raw.substring(0, colon);
      trust = FingerprintTrust.parse(raw.substring(colon + 1));
    }

    final track = switch (trackPart) {
      'o2' || 'po' || 'pq' || 'pqomemo' || 'omemo2' => Track.pq,
      'om' || 'standard' || 'standardomemo' => Track.standard,
      'no' || 'none' => Track.none,
      _ => null,
    };
    if (track == null) return EncModeToken.none;
    if (track == Track.none) return EncModeToken.none;
    return EncModeToken.of(track, trust: trust);
  }

  static const List<EncModeToken> values = [none, standard, pq, error];

  @override
  bool operator ==(Object other) =>
      other is EncModeToken && other.track == track && other.trust == trust;

  @override
  int get hashCode => Object.hash(track, trust);
}
