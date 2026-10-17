// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// What a message said before it was corrected (XEP-0308).
//
// `applyCorrection` overwrites `messages.body` in place and stamps
// `messages.edited_at`, and at that instant the previous text stops existing.
// This module is what stops that: the superseded renderings of one message,
// bounded, and destroyable.
//
// Three decisions live here, and each of them has a failure that a reviewer
// would otherwise have to notice the hard way:
//
//   * The list is bounded and the bound is *kept*, not refused. See
//     [kEditHistoryLimit] and [EditHistory.droppedOldest].
//   * A retraction destroys the whole history, without exception and without a
//     way back. See [onRetraction] — this is the security-relevant one.
//   * A history that is gone and a history that was never there are different
//     things and must not get the same words. See [redactEditHistory].

import 'dart:convert';

/// How many superseded renderings one message keeps.
///
/// Every version is a full copy of the body, and there is no ceiling on how
/// many times a message may be corrected — a sender in a loop, or a server
/// that keeps redelivering one stanza, will find the limit on every pass. Five
/// is comfortably more than anyone needs while actually fixing a message (typo,
/// wording, typo, wording, give up) and low enough that one hostile message
/// cannot turn a row into a transcript of its own.
///
/// The bound is on the number of versions, not on bytes. A body-size cap
/// belongs on the send path, where the text is still in our hands; here it
/// would only punish somebody for being edited by somebody else.
const int kEditHistoryLimit = 5;

/// Which of the three things a stored history can be.
///
/// These are terminal states, not flags: a history that cannot be read must not
/// be able to become readable by being written to again, and a history that was
/// destroyed must not be able to come back at all. Representing them as two
/// independent booleans would permit a "redacted but holding versions" value,
/// which is precisely the value this file must not be able to produce.
enum EditHistoryState {
  /// Versions are present and were written by us.
  readable,

  /// Deliberately destroyed, because the sender retracted the message.
  redacted,

  /// Stored bytes this build could not parse.
  ///
  /// Not the same as [redacted]: nobody chose this, and the versions may well
  /// still be sitting in the column.
  unreadable,
}

/// One rendering of a message body at one point in time.
///
/// Superseded by construction: a version exists only because something replaced
/// it, which is why [replacedAt] is not optional.
class MessageVersion {
  const MessageVersion({
    required this.body,
    required this.track,
    required this.replacedAt,
  });

  /// The text as it stood.
  ///
  /// May legitimately be empty. "The message was empty and was then given text"
  /// is a real correction, and flattening it to "nothing recorded" would be a
  /// different history.
  final String body;

  /// The token this body travelled on, spelled as `messages.enc_mode` spells it.
  ///
  /// A string rather than a `Track` because `omemo/track.dart` imports
  /// Flutter's `material.dart` for its icons, and this value has to be built by
  /// the store, read by the store, and constructed in a plain unit test. A
  /// widget library in the middle of a value type that is serialised to disk is
  /// a dependency nobody asked for.
  ///
  /// Stored per version because a correction is a *new* rendering of somebody's
  /// message, and this app labels every message with the track it actually
  /// used. A version without its track would let the history panel imply that a
  /// message was plaintext when it was not — or, worse, that a post-quantum
  /// message had gone out unencrypted at some point in its life. Both are lies
  /// about the past, and neither can be undone by relabelling the current row.
  ///
  /// Never normalised to a default. An empty or unrecognised token is kept as it
  /// found and rendered by [trackLabel] as unrecognised, because there is
  /// nothing left to protect by being uncertain about it — the text has already
  /// been sent — and defaulting it to `NO` would be a claim, not a default.
  final String track;

  /// When this rendering was replaced.
  ///
  /// Our clock at the moment the correction was applied, not the sender's:
  /// XEP-0308 carries no timestamp, so the only honest answer is when we saw it.
  final DateTime replacedAt;

  @override
  bool operator ==(Object other) =>
      other is MessageVersion &&
      other.body == body &&
      other.track == track &&
      other.replacedAt == replacedAt;

  @override
  int get hashCode => Object.hash(body, track, replacedAt);

  @override
  String toString() =>
      'MessageVersion($track, $replacedAt, '
      '${body.isEmpty ? '<empty>' : body})';
}

/// The superseded renderings of one message.
///
/// Immutable, and empty in every terminal state: there is no value of this type
/// that both reports [EditHistoryState.redacted] and carries a body.
class EditHistory {
  const EditHistory._(
    this.versions, {
    this.droppedOldest = false,
    this.state = EditHistoryState.readable,
  });

  /// No history at all: a message that was never corrected, or a column that
  /// predates this build.
  const EditHistory.empty() : this._(const <MessageVersion>[]);

  /// Destroyed on purpose. See [onRetraction].
  const EditHistory.redacted()
    : this._(const <MessageVersion>[], state: EditHistoryState.redacted);

  /// Stored, but not readable by this build.
  const EditHistory.unreadable()
    : this._(const <MessageVersion>[], state: EditHistoryState.unreadable);

  /// Builds a history, applying the bound.
  ///
  /// The one place [kEditHistoryLimit] is enforced, so that no route into a
  /// history — a correction, a decoded column, a hand-written test — can produce
  /// an over-long list. Dropping is oldest-first, which means [droppedOldest]
  /// is true exactly when the length here is the limit.
  factory EditHistory.of(Iterable<MessageVersion> versions) {
    final all = List<MessageVersion>.of(versions, growable: false);
    if (all.length <= kEditHistoryLimit) {
      return EditHistory._(List<MessageVersion>.unmodifiable(all));
    }
    return EditHistory._(
      List<MessageVersion>.unmodifiable(
        all.sublist(all.length - kEditHistoryLimit),
      ),
      droppedOldest: true,
    );
  }

  /// Oldest first. The order the corrections were applied in, which is the only
  /// order we can know: XEP-0308 says nothing about timing, and the store keeps
  /// dates at second precision, so sorting by [MessageVersion.replacedAt] would
  /// reorder ties into whatever the sort algorithm felt like.
  final List<MessageVersion> versions;

  /// True when the oldest versions were dropped to stay inside the bound.
  ///
  /// Sticky, and permanent. Once set, [originalBody] answers null for good: the
  /// text the message started with is gone and no amount of further editing puts
  /// it back. This flag is what keeps the history panel from promoting the
  /// oldest *surviving* version to "the original", which would be a fluent and
  /// completely false claim.
  final bool droppedOldest;

  final EditHistoryState state;

  /// Whether a word of it can be shown, whatever the state.
  bool get _hasReadableText =>
      state == EditHistoryState.readable && versions.isNotEmpty;

  /// Whether a word of it ever was.
  ///
  /// True for [EditHistoryState.unreadable], which is why this is separate from
  /// [_hasReadableText]: the reader still has to be told that an edit happened
  /// even when we cannot show any of it.
  bool get _isEdited => switch (state) {
    EditHistoryState.readable => versions.isNotEmpty,
    // Nothing to open. The "edited" marker on a bubble comes from
    // `messages.edited_at`, which survives a retraction on purpose, so the
    // two disagreeing here is correct rather than a bug to paper over.
    EditHistoryState.redacted => false,
    EditHistoryState.unreadable => true,
  };

  /// The oldest version still held, for display.
  ///
  /// Deliberately separate from [originalBody]: after truncation there *is* an
  /// oldest surviving version, and hiding it would throw away real text — but it
  /// has to be rendered as what it is, which is the gap between the two.
  MessageVersion? get oldestVersion => _hasReadableText ? versions.first : null;

  @override
  bool operator ==(Object other) {
    if (other is! EditHistory) return false;
    if (other.state != state) return false;
    if (other.droppedOldest != droppedOldest) return false;
    // Element-wise, because every list here is a fresh unmodifiable wrapper and
    // list `==` is identity: two histories decoded from the same bytes are the
    // same history, and a test that could not tell them apart would be testing
    // object allocation.
    if (other.versions.length != versions.length) return false;
    for (var i = 0; i < versions.length; i++) {
      if (versions[i] != other.versions[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(versions), droppedOldest, state);

  @override
  String toString() =>
      'EditHistory($state, ${versions.length} versions, '
      'droppedOldest: $droppedOldest)';
}

/// The text the message started with, or null when there is none to show.
///
/// Null means "there is no original to show" and never "the original was
/// empty" — an empty [MessageVersion.body] comes back as an empty string,
/// because a message that was blank and then given text has a history, and
/// reporting nothing for it would read as a broken client.
///
/// Null for an [EditHistoryState.redacted] history because the text has been
/// destroyed on purpose, and for an unreadable one because inventing a version
/// out of a parse failure would be inventing history that may not exist. Also
/// null once [EditHistory.droppedOldest] is set: the text the message started
/// with is gone and no further edit brings it back.
String? originalBody(EditHistory history) {
  if (!history._hasReadableText || history.droppedOldest) return null;
  return history.versions.first.body;
}

/// True when this message has earlier text on file.
///
/// "Is there something to open", which is the question the history panel asks —
/// *not* "was the body changed". Those come apart on purpose: a retracted
/// message is still edited (`messages.edited_at` says so and must keep saying
/// so, because the bubble's marker is a fact about what happened), while its
/// history is gone and must report so here.
bool isEdited(EditHistory history) => history._isEdited;

/// True when a correction changes nothing, so it must not be recorded.
///
/// The one replay-shaped question, and the reason it is answered here rather
/// than inside [recordEdit]: only the caller holds both texts. `applyCorrection`
/// is happy to re-apply an identical stanza — servers redeliver, and a carbon
/// reaches every one of our devices — so this fires on corrections nobody made.
///
/// It matters more than it looks, because of the bound: a replay consumes a slot
/// and moves the time the text was replaced, so one edit delivered six times
/// reports a message as edited six times and costs somebody the original. This
/// is also why the track is compared and not just the text: a correction that
/// re-sends the same words on a different track is a real change, and skipping
/// it would leave the message labelled with the track it stopped travelling on.
bool isNoOpCorrection({
  required String currentBody,
  required String currentTrack,
  required String newBody,
  required String newTrack,
}) => currentBody == newBody && currentTrack == newTrack;

/// The body this message had before [displacedAt], as a new history.
///
/// Note the direction of the argument. This is called at the moment the store
/// overwrites `messages.body`, and it records the text being *left behind*: the
/// replacement is written by the caller, and accepting it here as well would
/// store the current text as history — a value that looks exactly like a
/// message that was never corrected at all.
///
/// Two refusals, both of them about not destroying something we cannot account
/// for:
///
///  * A [EditHistoryState.redacted] history is terminal. A sender who retracts
///    and then corrects the same message has un-deleted it, and the message
///    comes back — but the history does not, and it cannot. Rebuilding one
///    would mean writing a chain whose first link is text we were told to
///    forget, and every version after it would sit on top of that forgery.
///  * An [EditHistoryState.unreadable] history is left alone. Appending to bytes
///    we failed to parse means overwriting a chain we cannot see, and the
///    version being displaced would be gone with no way to notice.
///
/// It deliberately does not try to recognise a replay — a correction from A to B
/// and one from B back to A leave the same two texts here as a duplicated
/// stanza does, and silently merging them would drop a real edit out of the
/// history on the strength of a guess. [isNoOpCorrection] is where that
/// judgement is made, with both texts in hand.
EditHistory recordEdit(
  EditHistory history,
  String displacedBody,
  String displacedTrack,
  DateTime displacedAt,
) {
  if (history.state != EditHistoryState.readable) return history;
  return EditHistory.of([
    ...history.versions,
    MessageVersion(
      body: displacedBody,
      track: displacedTrack,
      replacedAt: displacedAt,
    ),
  ]);
}

/// What happens to the history when the message is retracted for everyone
/// (XEP-0424).
///
/// A retraction drops the whole history.
///
/// "Delete for everyone" is an instruction to the recipient's own client, and
/// this client is one of those recipients. Keeping the previous text after
/// honouring it would make the retraction a gesture: the message would be
/// unreadable on the sender's screen and fully readable on ours — and not just
/// the current text either, but every typo the sender has already fixed and
/// would rather not have written down twice. The history is the most sensitive
/// part of the message, not the least.
///
/// It returns a fresh value rather than emptying the argument, so a caller that
/// kept its own reference cannot read the text back out of the "same" history
/// afterwards, and it is total: unreadable and empty histories are dropped too,
/// because "we could not parse it" is not a reason to keep a copy of a deleted
/// message. Dropping the argument's reference is the caller's job, and the
/// store's: only overwriting the column actually forgets the bytes.
///
/// Terminal. A later correction un-deletes the message, not the history.
EditHistory onRetraction(EditHistory history) =>
    history.state == EditHistoryState.redacted
    ? history
    : const EditHistory.redacted();

/// Words for the history panel, including when there is nothing to show.
///
/// The whole point of this function is that the *absent* cases have words. An
/// empty string in the "original" position reads as a message that was deleted,
/// a message whose history was dropped, and a message that was blank when it
/// was sent — three unrelated things, and a reader who cannot tell them apart
/// concludes the client is broken. Which is the failure this module exists to
/// prevent: not storing the text is honest as long as we say so.
String redactEditHistory(EditHistory history) {
  if (history.state == EditHistoryState.redacted) {
    return kHistoryRedactedNotice;
  }
  if (history.state == EditHistoryState.unreadable) {
    return kHistoryUnreadableNotice;
  }
  if (history.versions.isEmpty) return kHistoryEmptyNotice;
  // Checked before the body so a truncated history can never label the oldest
  // survivor as the original. The number it lost is [kEditHistoryLimit].
  if (history.droppedOldest) return kHistoryTruncatedNotice;
  final original = history.versions.first.body;
  return original.isEmpty
      ? kHistoryEmptyOriginalNotice
      : 'Originally: $original';
}

/// Shown in place of the original text of a retracted message.
///
/// Says the text went *with* the message. The reader needs to understand that
/// there is nothing left to retrieve, because the natural question after "this
/// message was deleted" is "can I still see the old version?".
const kHistoryRedactedNotice =
    'This message was deleted, and the text it was edited from went with it';

/// Shown when the stored history could not be parsed.
///
/// Says the history is unreadable rather than absent, because the difference is
/// the difference between "there is nothing there" and "something is there and
/// we cannot show it", and only one of those is our fault.
const kHistoryUnreadableNotice =
    'This message was edited, and the earlier text could not be read';

/// Shown when the oldest versions were dropped to stay inside the bound.
///
/// Deliberately does not name the count: the number is a storage decision that
/// will change, and a reader who is told "the first 12 of 14 versions were
/// dropped" learns nothing they can act on.
const kHistoryTruncatedNotice =
    'The text this message started with is no longer stored — it was edited '
    'more times than are kept';

/// Shown when a message carries no history and never had one.
const kHistoryEmptyNotice = 'No earlier version is stored for this message';

/// Shown when the original text really was empty.
///
/// The only honest reading, and the one that stops an empty message corrected
/// into real text from looking like a history we failed to keep.
const kHistoryEmptyOriginalNotice = 'The original message was empty';

/// Shown for a track token this build does not recognise.
const kTrackUnknownLabel = 'unrecognised track';

/// The words for a stored track token.
///
/// The three canonical spellings are repeated here rather than imported from
/// `omemo/track.dart`, which would pull Flutter into a value type; a fourth
/// track added there falls into the unknown branch, which is the direction that
/// fails safe. So does `error`: it is a real token meaning "encrypted by
/// something we cannot read", and calling it unrecognised is imprecise but very
/// much better than falling through to plaintext.
///
/// Never returns anything that reads as "plaintext" for a token that is not
/// `NO`. That is the whole contract: an unlabelled message implies the clear,
/// and the history panel is a place where that implication would be made about
/// a message that has already left the device.
String trackLabel(String token) => switch (token.trim().toLowerCase()) {
  'no' || 'none' => 'plaintext',
  'om' || 'standard' || 'standardomemo' => 'standard OMEMO',
  'po' || 'pq' || 'pqomemo' => 'post-quantum',
  'error' => 'encrypted by something this app cannot read',
  _ => kTrackUnknownLabel,
};

/// The column value for [history].
///
/// JSON rather than a `edit_versions` table, because the retraction has to be
/// able to destroy the history *without* touching the message — the body is kept
/// on purpose — and one nullable column is the only shape where "forget it" is
/// a single write that cannot leave an orphaned version row behind holding the
/// text somebody asked us to delete.
///
/// Encoding an unreadable history records the verdict, not the bytes: the raw
/// text stays in the column until the next write, and from then on this build
/// says "could not be read" rather than inventing a chain it does not have.
String encodeEditHistory(EditHistory history) => switch (history.state) {
  EditHistoryState.redacted => '{"redacted":true}',
  EditHistoryState.unreadable => '{"unreadable":true}',
  EditHistoryState.readable => jsonEncode([
    for (final v in history.versions)
      {
        'body': v.body,
        'track': v.track,
        'at': v.replacedAt.toUtc().toIso8601String(),
      },
  ]),
};

/// Reads back what [encodeEditHistory] wrote.
///
/// Total: no input throws, because a column this build cannot parse must not be
/// able to make a whole transcript unreadable. A failure becomes
/// [EditHistoryState.unreadable], which says so — not an empty history, which
/// would claim the message was never edited.
///
/// All or nothing, too. A list where one entry is corrupt would otherwise render
/// as a complete-looking chain with a hole in the middle, and the version order
/// *is* the chain: there is no way to tell the reader which step went missing.
EditHistory decodeEditHistory(String? raw) {
  if (raw == null || raw.isEmpty) return const EditHistory.empty();
  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    return const EditHistory.unreadable();
  }
  if (decoded is Map) {
    return decoded['redacted'] == true
        ? const EditHistory.redacted()
        : const EditHistory.unreadable();
  }
  if (decoded is! List) return const EditHistory.unreadable();
  final versions = <MessageVersion>[];
  for (final entry in decoded) {
    if (entry is! Map) return const EditHistory.unreadable();
    final Object? body = entry['body'];
    final Object? track = entry['track'];
    final Object? at = entry['at'];
    if (body is! String || (track != null && track is! String)) {
      return const EditHistory.unreadable();
    }
    final parsed = at is String ? DateTime.tryParse(at) : null;
    if (parsed == null) return const EditHistory.unreadable();
    // A missing track stays missing. Defaulting it would be the one lie this
    // module cannot make: see MessageVersion.track.
    versions.add(
      MessageVersion(
        body: body,
        track: track is String ? track : '',
        replacedAt: parsed,
      ),
    );
  }
  // Re-bounded here as well, so a column edited by hand or written by a build
  // with a larger limit cannot exceed ours.
  return EditHistory.of(versions);
}
