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

import '../../l10n/generated/app_localizations.dart';

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
/// Deliberately a closed vocabulary: the column is a database contract, and
/// binding it to a Dart enum identifier would let a rename silently rewrite
/// history.
///
/// The stored spelling is [Track.stored] — the same two letters the user
/// reads under a message — so the column and [chats.track_override] cannot
/// disagree about what "pq" was called. [error] is the only value with a
/// spelling of its own, because it is a condition rather than a track: a
/// message that was encrypted by something we cannot read.
enum EncModeToken {
  none(Track.none),
  standard(Track.standard),
  pq(Track.pq),
  error(null);

  const EncModeToken(this.track);

  /// The track this token records, or null for [error].
  final Track? track;

  /// The stored form.
  String get wire => track?.stored ?? 'error';

  /// The token for [track].
  static EncModeToken of(Track track) => switch (track) {
    Track.none => EncModeToken.none,
    Track.standard => EncModeToken.standard,
    Track.pq => EncModeToken.pq,
  };

  /// Reads a stored value, including every spelling earlier builds wrote.
  ///
  /// An unrecognised value resolves to [none] rather than throwing: a single
  /// corrupt row must not make the whole history unreadable. Note this is the
  /// one place where "give up and treat as plaintext" is acceptable, because
  /// the value describes a message that was *already sent* — there is nothing
  /// left to protect by being uncertain about it. The same uncertainty on the
  /// send path is not acceptable, which is why [fromStored] returns null.
  static EncModeToken parse(String? value) => switch (value?.toLowerCase()) {
    'o2' || 'po' || 'pq' || 'pqomemo' || 'omemo2' => EncModeToken.pq,
    'om' || 'standard' || 'standardomemo' => EncModeToken.standard,
    'no' || 'none' => EncModeToken.none,
    'error' => EncModeToken.error,
    _ => EncModeToken.none,
  };
}
