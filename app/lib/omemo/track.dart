// Copyright (C) 2026 resonchat contributors.
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

  /// resonchat's post-quantum track (PQ-OMEMO).
  pq(label: 'PO', icon: Icons.shield);

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

  /// Human-readable label for the track picker.
  String get description => switch (this) {
        Track.none => 'Plaintext — anyone with access to the server can read '
            'this.',
        Track.standard =>
          'Standard OMEMO — readable by other XMPP apps such as Conversations.',
        Track.pq => 'Post-quantum — strongest, but only resonchat apps can read '
            'it.',
      };

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
        ExplicitEncryptionType.omemo2 =>
          Track.standard,
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
        ExplicitEncryptionType.unknown =>
          true,
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
        'po' || 'pq' || 'pqomemo' => Track.pq,
        'om' || 'standard' || 'standardomemo' => Track.standard,
        'no' || 'none' => Track.none,
        _ => null,
      };
}

/// The token stored in `messages.enc_mode`.
///
/// Deliberately a closed vocabulary: the column is a database contract, and
/// binding it to a Dart enum identifier would let a rename silently rewrite
/// history. [error] is not a track but a condition — an encrypted message we
/// could not open — and it shares the column because the UI needs to say
/// "this was encrypted, but not by us" in one place.
enum EncModeToken {
  none('none'),
  standard('standard'),
  pq('pq'),
  error('error');

  const EncModeToken(this.wire);

  final String wire;

  static EncModeToken parse(String? value) => switch (value) {
        'standard' || 'standardOmemo' => EncModeToken.standard,
        'pq' || 'pqOmemo' => EncModeToken.pq,
        'error' => EncModeToken.error,
        _ => EncModeToken.none,
      };

  Track? get track => switch (this) {
        EncModeToken.none => Track.none,
        EncModeToken.standard => Track.standard,
        EncModeToken.pq => Track.pq,
        EncModeToken.error => null,
      };
}