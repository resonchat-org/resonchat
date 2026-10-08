// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Message reactions (XEP-0444).
//
// Reactions are metadata about a message, not a message. That single fact
// drives every decision in this file:
//
//   * They go out **unencrypted**. Wrapping a reaction in OMEMO hides it from
//     every client that is not us, so the sender's other devices — and
//     Conversations, and Signal — would never see it. A reaction the other
//     person cannot see is not a reaction.
//   * They reference the target by its **origin-id** (XEP-0359), because that
//     is the id that survives archiving and replay.
//   * A broadcast is a reactor's **complete** set, not a delta. Emptying the
//     list is how someone takes a reaction back, so the receiver has to
//     replace rather than merge.

import 'package:moxxmpp/moxxmpp.dart' show JID;

import '../store/database.dart';
import 'connection.dart';

/// The emoji offered without opening a picker.
///
/// Deliberately a short list of single-code-point characters. Reactions cross
/// clients, so a character that one client draws as a coloured emoji and
/// another draws as a monochrome glyph is a broken chip — and a sequence (a
/// variation selector, a skin tone, a ZWJ join) is exactly how that happens.
/// Hence `❤` (U+2764) rather than `❤️`: the latter is two code points, and the
/// trailing variation selector is what decides whether it renders as a heart
/// pictograph or as text.
const kQuickReactions = <String>['👍', '❤', '😂', '😮', '😢', '🙏'];

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

/// One emoji and the people who chose it, as the UI needs it.
class ReactionGroup {
  const ReactionGroup({
    required this.emoji,
    required this.reactors,
    required this.mine,
  });

  final String emoji;

  /// Bare JIDs, so two devices of one person can be told apart — a user
  /// reacting from their phone and laptop is two reactions, which is what every
  /// other client shows.
  final Set<String> reactors;

  /// True when one of them is us. Decides the chip's tint, and is what makes
  /// tapping it withdraw rather than add.
  final bool mine;

  int get count => reactors.length;

  factory ReactionGroup.fromRow(
    ({String emoji, Set<String> reactors, bool mine}) row,
  ) {
    return ReactionGroup(
      emoji: row.emoji,
      reactors: row.reactors,
      mine: row.mine,
    );
  }
}

/// Stores one broadcast, replacing that reactor's previous set for the target.
Future<void> storeReaction(AppDatabase db, ReactionUpdate update) {
  return db.setReactions(
    targetId: update.targetId,
    reactor: update.reactor,
    emojis: update.emojis,
  );
}

/// Reaction chips for [targetId], ready to hand to a bubble.
Future<List<ReactionGroup>> reactionsFor(
  AppDatabase db,
  String targetId,
  String myJid,
) async {
  final rows = await db.reactionGroups(targetId, myJid: myJid);
  return rows.map(ReactionGroup.fromRow).toList();
}

/// Sends [emojis] on [targetId] to the conversation with [to].
///
/// Returns false when the stanza could not be sent, so the caller can undo its
/// optimistic chip. A reaction that silently fails is indistinguishable from one
/// the server ignored, and the sender would see their own emoji missing with no
/// way to tell the network apart from their client.
Future<bool> sendReaction(
  XmppService xmpp, {
  required JID to,
  required String targetId,
  required List<String> emojis,
}) {
  return xmpp.setReactions(to, targetId: targetId, emojis: emojis);
}
