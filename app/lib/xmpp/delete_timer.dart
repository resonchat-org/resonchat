// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// "Delete messages after": automatic expiry of local history, per conversation
// or for the whole account.
//
// The one thing this feature is not, and the reason several rules below look
// stricter than the interface that exposes them: **it deletes from this device
// only**. Nothing here retracts. The other party's client is never told, their
// copy is untouched, and anything the server still holds (XEP-0313) is stored
// again on the next history fetch. So the only promise this feature can make is
// "not on this device right now" — never "gone" — and every screen that offers
// it has to say exactly that. A user who believes the messages no longer exist
// anywhere is *less* careful about what they type next, not more.
//
// The corollary is the second decision here: a sweep must never retract. The
// timer is a standing instruction given once, in the abstract, and the sweep
// that carries it out runs with nobody watching. Turning that into a burst of
// XEP-0424 broadcasts would tell every recipient that messages were deleted —
// by us, for a reason they were never asked about — and it would race the
// user's own manual retractions, so "deleted" messages would reappear.
//
// Three more things this file refuses to do, each of which looks like an
// omission until you picture the failure:
//
//   * **It never deletes a message that arrived before the timer was switched
//     on.** Not after a grace period — never. See [isEligibleForDeletion].
//   * **It never deletes outgoing messages** unless the caller explicitly opts
//     out. See [isEligibleForDeletion].
//   * **It never touches `plaintext_ack:<chat>`.** See below.
//
// On pins: pinning is an explicit statement about one specific message;
// a timer is a blanket rule the user set once and forgot. The specific beats
// the general, so a pin is an exemption and not merely a delay. Unpinning does
// not restore the exemption's *effect*: the message becomes eligible again on
// the next sweep, because a pin that outlives its row would be a promise about
// nothing and the UI would be claiming to protect history it has thrown away.
//
// On `plaintext_ack:<chat>` (the meta row that records "the user has agreed to
// send in the clear here"): a sweep writes no meta rows at all. Neither
// direction. Clearing it re-arms the plaintext warning once per interval, and
// under the 30-second interval that is once per message — which is precisely
// the failure the existing acknowledgement rule was written to avoid, where a
// warning repeated this often stops being read. Setting it from a row that was
// just deleted would grant consent for messages the user never saw. The
// acknowledgement is about the *track*, not about the history, and history is
// not what anybody consented to. For the same reason the draft is exempt: a
// draft is unsent plaintext the user is holding right now, it lives in
// `draft:<chat>` rather than in `messages`, and a sweep has no business
// reading or cleaning it up.

/// How long a message is kept once the timer is running.
///
/// A closed set, and that is the whole argument for the type existing. A
/// free-text interval lets a user reach a state like "delete after 10 seconds"
/// and lose a message they meant to keep, and it does so without ever
/// displaying anything they could recognise as the cause. There is no value
/// here that removes more than the user was shown, and there is no value here
/// that was not offered to them as a choice.
///
/// [off] is a value rather than a null, so that "never delete" is something the
/// user picked and the interface can show, rather than a row that is absent.
enum DeleteInterval {
  off(stored: 'off'),

  /// Short enough to be a demo, long enough to read and answer.
  thirtySeconds(stored: '30s', age: Duration(seconds: 30)),

  oneHour(stored: '1h', age: Duration(hours: 1)),

  oneDay(stored: '1d', age: Duration(days: 1)),

  oneWeek(stored: '1w', age: Duration(days: 7));

  const DeleteInterval({required this.stored, this.age});

  /// The token written to `chats.delete_interval`.
  ///
  /// Fixed spellings rather than the enum identifier, because the column is a
  /// database contract: a rename in Dart must not silently rewrite what every
  /// stored setting means.
  final String stored;

  /// How long a message may live, or null for [off].
  ///
  /// Null rather than [Duration.zero] because "delete everything immediately"
  /// is not one of the choices, and it must not be reachable by arithmetic on
  /// this value.
  final Duration? age;

  /// True when this interval deletes anything at all.
  bool get deletes => age != null;

  /// The short name for a picker row.
  String get label => switch (this) {
    DeleteInterval.off => 'Off',
    DeleteInterval.thirtySeconds => '30 seconds',
    DeleteInterval.oneHour => '1 hour',
    DeleteInterval.oneDay => '1 day',
    DeleteInterval.oneWeek => '1 week',
  };

  /// Reads a stored token, resolving anything unrecognised to [off].
  ///
  /// Unlike the track column, where an unreadable value has to be handed back
  /// as null because both possible defaults cost something, here there is only
  /// one safe direction: a corrupt setting must not start deleting a
  /// conversation. A restored backup, a hand-edited row and a future build's
  /// spelling all land on "off", which is the state a fresh install is in
  /// anyway.
  static DeleteInterval fromStored(String? value) => switch (value) {
    '30s' => DeleteInterval.thirtySeconds,
    '1h' => DeleteInterval.oneHour,
    '1d' => DeleteInterval.oneDay,
    '1w' => DeleteInterval.oneWeek,
    _ => DeleteInterval.off,
  };
}

/// Wording for the interval picker.
///
/// Kept apart from the widgets so the phrases can be reviewed — and tested —
/// without rendering anything. [locality] is the sentence that must not be
/// dropped when someone shortens these for a narrower screen: without it the
/// feature reads as "delete for everyone", and the difference is the entire
/// privacy story.
extension DeleteIntervalText on DeleteInterval {
  String get description => switch (this) {
    DeleteInterval.off =>
      'Keep everything. Nothing is ever deleted from this device.',
    DeleteInterval.thirtySeconds =>
      'Delete each message from this device 30 seconds after it arrives.',
    DeleteInterval.oneHour =>
      'Delete each message from this device an hour after it arrives.',
    DeleteInterval.oneDay =>
      'Delete each message from this device a day after it arrives.',
    DeleteInterval.oneWeek =>
      'Delete each message from this device a week after it arrives.',
  };

  /// The consequence a user cannot guess on their own.
  ///
  /// Named for the UI to show as a second line under the picker rather than
  /// folding into [description], because it is the same sentence for every
  /// interval and only means something once a value has been chosen.
  static String get locality =>
      'Messages are deleted from this device only. The other person keeps '
      'their copy, they are not told, and anything the server still holds can '
      'come back on the next history fetch.';
}

/// The fields of one stored message this module needs.
///
/// A record rather than the row type on purpose: this file takes no dependency
/// on the store, and a `pinned` flag has to be joined in from another table
/// anyway. Keeping the inputs to four scalars is what lets the rules be tested
/// without a database.
typedef StoredMessage = ({
  int id,
  DateTime timestamp,

  /// Answered from `pinned_messages`, not from `messages`.
  bool pinned,

  /// True when *we* wrote this. Must be answered as `!incoming || isCarbon`:
  /// a carbon copy of our own message is ours too, and exempting the copy that
  /// arrives from another device while deleting the one sent from this one
  /// would leave two renderings of the same message with different fates.
  bool outgoing,
});

/// Whether the stored message may be deleted at [now].
///
/// The interval arrives as a [Duration] and not as a [DeleteInterval] so that a
/// value nothing in this app can produce is still representable. A stored
/// setting that has been restored from somewhere else, or computed by a caller
/// that got it wrong, is exactly the input that must not be able to delete a
/// conversation, and an enum would make that input unrepresentable instead of
/// handled. Callers pass `setting.age`, which is null for off.
///
/// [armedAt] is the instant the timer was switched on for this conversation,
/// or null when the conversation is not armed. It is a separate input rather
/// than something derived from [interval] because the two change at different
/// times: re-choosing an interval is not re-arming, so [armedAt] must survive
/// it, and only a move from off to on moves the origin.
bool isEligibleForDeletion({
  required Duration? interval,
  required DateTime? armedAt,
  required DateTime timestamp,
  required DateTime now,
  required bool pinned,
  required bool outgoing,
  required bool hasDraft,
}) {
  // Off is not "no age yet". It is the answer to "should anything ever be
  // deleted here", and it is the state of every conversation on a fresh
  // install, so returning anything but false for it would mean a user who has
  // never opened this feature loses messages.
  if (interval == null) return false;

  // A zero or negative interval means the stored value is corrupt, not that
  // the user asked for instant deletion. No such choice exists in the picker,
  // so honouring it would be inventing one — and the invention empties the
  // whole conversation on the first sweep after the corruption, with nothing
  // on screen to explain it. Fail closed.
  if (interval <= Duration.zero) return false;

  // A draft anywhere in the conversation holds the entire sweep, not just the
  // newest messages. The user is composing a reply to what they are reading
  // right now, so the transcript changing under them loses their place and
  // their reference at the exact moment they are least able to notice.
  if (hasDraft) return false;

  // Armed means "we know when the rule started". Without that, every row in
  // the conversation predates the rule by definition, and the only honest
  // outcome is to delete none of them.
  if (armedAt == null) return false;

  // Nothing that predates the arming instant is deletable, however old it is.
  //
  // [armedAt] is a *precondition*, not a detail this function derives: it is
  // the moment the current interval took effect. Its entire job is to make
  // **changing** the interval safe, and it only does that if the caller
  // refreshes it on every change — see `setDeleteInterval`.
  //
  // The failure it prevents is worth stating because it is not obvious until
  // you say it aloud: a user has a week-long timer and has read three months
  // of history, then shortens the interval to thirty seconds because they now
  // want fast expiry. Those three-month-old messages were never eligible under
  // a week — and after the change they are. Without a refreshed arming instant
  // the very next sweep deletes months of conversation the user has already
  // read, irreversibly, triggered by a settings change that reads as
  // innocuous. There is no undo for a bulk delete.
  //
  // A grace period does not fix it either: it only postpones the deletion, and
  // the user watches the transcript change underneath them with even less
  // context for why.
  //
  // The cost, stated plainly: shortening the interval does not shorten anything
  // already on disk. Messages that arrived after the change age out on the new
  // schedule; everything older waits for its own timer. That is the only
  // reading under which changing a setting cannot destroy data the user did
  // not choose to destroy.
  //
  // Note what this does *not* say: a message that arrived *after* arming is
  // fully subject to the current interval, even if it arrived while a longer
  // one was in force. Reading it the other way would make the feature delete
  // nothing at all.
  if (timestamp.isBefore(armedAt)) return false;

  // A pin is a decision about this one message; the timer is a rule about all
  // of them. The specific one wins, so the message stays.
  if (pinned) return false;

  // Outgoing messages are exempt, which is the decision most likely to look
  // wrong from the outside.
  //
  // The timer exists so this device stops holding what it does not need. For
  // an incoming message, dropping our copy does that. For an outgoing one it
  // does not: we wrote it, we know what it says, and the row being deleted is
  // the only local record of what was sent and what it was sent as — the
  // peer's copy may have been deleted on their side, their client may never
  // have stored it, and the server's archive may have expired. So deleting it
  // protects nobody and can destroy the only copy there is.
  //
  // The two failure directions are not symmetric, which is the whole argument:
  // keeping one too long leaves text on a device the user controls and has
  // already expressed an opinion about, while deleting one too early is
  // unrecoverable and unfalsifiable.
  //
  // A caller that wants the symmetric behaviour has to say so, because it is a
  // different feature and the difference is not visible in the settings.
  if (outgoing) return false;

  // A message stamped in the future — a skewed clock, an archive replay that
  // carries the sender's time — is not yet due, and must not be treated as
  // arbitrarily old. Reached here rather than special-cased, because a negative
  // age is genuinely "not enough time has passed".
  final age = now.difference(timestamp);
  return age >= interval;
}

/// How many message ids one sweep may hand to a single `DELETE`.
///
/// Bounded because the batch becomes a bound-parameter list, and SQLite's
/// limit is a build-time number in the low thousands. A statement with ten
/// thousand placeholders does not merely run slowly, it fails — inside a
/// transaction that has already taken the write lock, so the failure is a
/// rollback of everything the sweep did rather than a partial clean-up.
///
/// This is the only limit in the module. The *eligible* set is deliberately
/// unbounded; what is capped is the size of one statement.
const int kMaxDeleteBatch = 500;

/// The rows one sweep would delete.
class DeleteBatch {
  const DeleteBatch({required this.ids, required this.moreRemaining});

  /// Nothing to delete, without having looked at anything.
  const DeleteBatch.empty() : ids = const <int>[], moreRemaining = false;

  /// The rows to delete in this sweep, at most [kMaxDeleteBatch] of them.
  ///
  /// Already unmodifiable when it came from [deleteBatchFor].
  final List<int> ids;

  /// True when eligible rows exist beyond this batch.
  ///
  /// Distinct from "the conversation is finished": a caller that reports
  /// nothing at all when [ids] is short would be claiming there is nothing
  /// left while the backlog is still growing.
  final bool moreRemaining;

  /// How many rows this sweep removes.
  ///
  /// The size of [ids] and never the number of eligible rows. A caller that
  /// says "deleted 4,000" after deleting 500 has told the user something that
  /// is false, and the difference is only visible later, when the rest of the
  /// backlog turns up in one large step.
  int get count => ids.length;
}

/// The rows a single sweep over [rows] would delete.
///
/// [rows] is expected to be one conversation's messages with the pin flag
/// already joined in; passing several conversations at once is a caller bug and
/// the result is a batch that mixes them, which is worth knowing rather than
/// discovering.
///
/// Returns a **bounded batch, never every match** — see [kMaxDeleteBatch]. The
/// order within the batch is oldest first, so a backlog drains from the end
/// that the timer's privacy promise is actually about, and so a capped batch
/// always makes visible progress instead of leaving the same few thousand rows
/// for ever. A sweep that deletes everything at once is an outage wearing the
/// costume of a cleanup.
///
/// Eligibility is decided by [isEligibleForDeletion] rather than by a second
/// copy of the rules: two implementations of the pin or draft exemption in one
/// codebase is how they come to disagree, and the disagreement shows up as
/// messages the sweep deletes that the UI promised were safe.
DeleteBatch deleteBatchFor({
  required Duration? interval,
  required DateTime? armedAt,
  required DateTime now,
  required bool hasDraft,
  required List<StoredMessage> rows,
  int limit = kMaxDeleteBatch,
}) {
  // Answered before the rows are looked at. Off and "there is a draft" both
  // mean no sweep happens at all, and refusing without reading is both cheaper
  // and one fewer place for a row to be misjudged on the way in.
  if (interval == null) return const DeleteBatch.empty();
  if (hasDraft) return const DeleteBatch.empty();

  // A limit of zero means "delete nothing this time", which is a real answer
  // from a caller that has work to do later. Clamping it up to the default
  // would perform a deletion the caller explicitly declined.
  if (limit <= 0) return const DeleteBatch.empty();

  // Compared by id, because the caller may have produced these rows by a query
  // that yields the same message twice — a UNION of two sources, or a join that
  // found a message twice. A duplicate here becomes a duplicate in a `DELETE
  // ... IN (...)` list, which is harmless to the database and wrong in the
  // count the user is shown.
  final seen = <int>{};
  final due = <StoredMessage>[];
  for (final row in rows) {
    if (!isEligibleForDeletion(
      interval: interval,
      armedAt: armedAt,
      timestamp: row.timestamp,
      now: now,
      pinned: row.pinned,
      outgoing: row.outgoing,
      hasDraft: hasDraft,
    )) {
      continue;
    }
    if (!seen.add(row.id)) continue;
    due.add(row);
  }

  // The id tiebreaker is not decoration: stored timestamps have second
  // precision, so a burst of messages inside one second would otherwise be
  // deleted in whatever order the query happened to return, and the batch
  // would stop being reproducible for the same input.
  due.sort((a, b) {
    final byTime = a.timestamp.compareTo(b.timestamp);
    return byTime != 0 ? byTime : a.id.compareTo(b.id);
  });

  final taken = due.length <= limit ? due : due.sublist(0, limit);
  return DeleteBatch(
    ids: List<int>.unmodifiable(taken.map((r) => r.id)),
    moreRemaining: due.length > taken.length,
  );
}

/// Why a message cannot be brought back.
///
/// Each case is a different thing that has to be true, so a screen that wants
/// to explain itself can say which one failed instead of hiding the button for
/// no visible reason.
enum UndeleteRefusal {
  /// The message is pinned, and a pinned message is never deleted, so there is
  /// nothing to undo. Offering "Undo" here would suggest the timer had removed
  /// a message it plainly still has.
  stillHere,

  /// No origin-id. The server archive and a carbon from another device both
  /// address messages by one, so a message without it cannot be asked for by
  /// anyone — including the copy we are trying to recover from.
  unaddressable,

  /// Nothing else holds a copy. The peer's client may have cleared it, their
  /// backup may have expired, and the server's archive may never have had it.
  /// This is the case the local-only promise in this file's header creates, and
  /// it is why "Undo" cannot be offered on the strength of hope.
  nothingLeftToFetchFrom,
}

/// Why a message cannot be undeleted, or null when it can.
///
/// Every piece of evidence defaults to false, so a caller that knows nothing —
/// or a future caller that forgets to ask — gets a refusal rather than a
/// recovery it cannot perform. A feature that offers "Undo" for something it
/// cannot undo is worse than one that offers no undo at all: the first is
/// discovered at the moment the user relies on it, when the message is already
/// gone and the tap has already been counted.
///
/// Every parameter defaults to false, [pinned] included: a caller cannot have
/// omitted the one that would have made the answer permissive.
UndeleteRefusal? undeleteRefusal({
  bool pinned = false,
  bool addressable = false,
  bool copyExistsElsewhere = false,
}) {
  if (pinned) return UndeleteRefusal.stillHere;
  if (!addressable) return UndeleteRefusal.unaddressable;
  if (!copyExistsElsewhere) return UndeleteRefusal.nothingLeftToFetchFrom;
  return null;
}

/// Whether [messageId] may be undeleted.
///
/// A convenience over [undeleteRefusal] for the case where only the answer
/// matters. [messageId] is carried so a caller cannot accidentally check the
/// recoverability of the *current* selection while intending the message the
/// undo button belongs to — a mismatch that would recover nothing and report
/// that it had.
///
/// Note that recovery does not disarm the timer. A restored row is subject to
/// the same rule from the moment it comes back, which makes undo a reprieve
/// rather than a reversal; the alternative, exempting restored rows, would mean
/// a message that keeps its immunity once it has been recovered, and the user
/// would have no way to tell those two states apart.
bool canUndelete({
  required int messageId,
  bool pinned = false,
  bool addressable = false,
  bool copyExistsElsewhere = false,
}) {
  if (messageId <= 0) return false;
  final refusal = undeleteRefusal(
    pinned: pinned,
    addressable: addressable,
    copyExistsElsewhere: copyExistsElsewhere,
  );
  return refusal == null;
}
