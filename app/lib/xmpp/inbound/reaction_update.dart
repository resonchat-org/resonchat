// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

/// One reaction broadcast, as it arrived or as it is about to be sent.
class ReactionUpdate {
  const ReactionUpdate({
    required this.targetId,
    required this.reactor,
    required this.emojis,
  });

  /// Origin-id of the message reacted to.
  final String targetId;

  /// Bare JID of the reactor.
  final String reactor;

  /// The reactor's complete set. Empty means "no reaction".
  final List<String> emojis;

  bool get isEmpty => emojis.isEmpty;
}
