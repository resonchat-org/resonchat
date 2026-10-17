// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Whether an inbound message should notify, and what a notification may say.
//
// The split this file enforces: the *policy* is here, the *mechanism* is not.
// Posting a notification is the part that changes with every Android release
// and every OEM skin — channel importance, heads-up permission, the
// POST_NOTIFICATIONS runtime prompt (asked on first shade post, not at
// launch), a per-app battery exemption — while what we want said when somebody
// writes to us has not changed in twenty years. A file that mixes the two gets
// rewritten per platform release with the judgement calls buried in the middle
// of channel plumbing, and the judgement calls are the only part worth reviewing.
//
// Three of the decisions below look arbitrary and are not:
//
//   * A carbon never notifies. It is a copy of a message this user wrote,
//     arriving from another of their own devices. Notifying about it means the
//     phone buzzes for the user's own typing, which teaches them that
//     notifications are noise — and they reach for "turn them all off", which
//     is the one outcome that costs every other message too.
//
//   * A message we could not open is announced but never described. Its body is
//     empty in our store and the only text we hold is a placeholder that
//     describes *our* failure, not their message. Putting that on a lock screen
//     shows the user something true and useless; leaving the notification out
//     entirely makes them wonder whether anything arrived. So the notification
//     stands, and says only that a message arrived — see [previewText].
//
//   * A mute is not a mute if the other person may type your name into it.
//     A direct mention is the one thing in a stream the user deliberately
//     silenced that they asked to hear; swallowing it is how a user ends up
//     disabling notifications for everything. See `mentionsUser`.
//
// Every rule below is ordered, first match wins, and the order *is* the
// policy: the silencing rules come before the alert rules so that nothing can
// be un-silenced by arriving in a louder state (see the muted/archived note).

/// The line a notification shows when there is nothing honest to put there.
///
/// One constant for every such case — an undecryptable message, a body with no
/// text, a message from a blocked sender — because the wording is the security
/// property, not an implementation detail, and a second copy of the sentence
/// would be a second thing to get wrong.
///
/// States one fact and only one: something arrived. It does not say what, so it
/// cannot mislead anybody on the other side of the lock screen.
const String kNoPreviewText = 'New message';

/// Longest preview before it is cut.
///
/// A notification is one line on a phone that is being glanced at while being
/// walked with. Enough to recognise the message, short enough that the whole
/// thing still fits — a preview that wraps is a preview nobody reads.
const int kMaxPreviewLength = 80;

/// The closed vocabulary of [NotifyDecision.reason].
///
/// A `String` rather than an enum because the mechanism wants to log and filter
/// on it, and because a decision that came from somewhere else can still be
/// reported. But it is a closed set: every decision names one of these, so a
/// silence is never unexplained.
///
/// Load-bearing: "no notification appeared" is indistinguishable from "the
/// message never arrived" unless the app can say which rule dropped it. A bug
/// that suppresses notifications for a reason nobody wrote down is
/// indistinguishable from a working mute, and gets reported as a delivery bug.
class NotifyReason {
  const NotifyReason._();

  /// The sender is blocked, so nothing is said. See `blocking.dart`.
  static const String blocked = 'blocked';

  /// A copy of one of our own messages from another of our own devices.
  static const String carbon = 'carbon';

  /// The user is looking at this conversation right now.
  static const String readingThisConversation = 'readingThisConversation';

  /// The conversation was moved to the archive.
  static const String archived = 'archived';

  /// Conversations "notify never" — no alert, even for highlights.
  static const String muted = 'muted';

  /// Highlight-only mode, and this message did not address us.
  static const String notHighlighted = 'notHighlighted';

  /// Alert because the message highlighted us (nick / MUC PM).
  static const String highlighted = 'highlighted';

  /// Former name of [highlighted]; kept so older logs stay searchable.
  static const String mentionedInMutedConversation = highlighted;

  /// The app is in front of the user.
  static const String appInForeground = 'appInForeground';

  /// The message arrived but we could not open it.
  static const String undecryptable = 'undecryptable';

  /// Nothing objected. The ordinary case.
  static const String incoming = 'incoming';
}

/// What a caller should do about one inbound message.
///
/// Four separate flags rather than one, because they answer different questions
/// and are wrong independently:
///
///   * [post] — should anything reach the notification shade at all.
///   * [sound] — should the device make a noise and vibrate.
///   * [banner] — should a heads-up card interrupt whatever is on screen.
///   * [includePreview] — may the message text be put in front of a lock
///     screen, on the assumption that whoever is holding the phone is the user
///     and authorised to read it. They frequently are not.
///
/// [countsAsUnread] is here too, though it belongs to the badge rather than the
/// notification. It is in this type because the two are decided from the same
/// facts and must never disagree: a conversation that shows no badge and still
/// buzzes is a bug report about one app, and so is the reverse.
class NotifyDecision {
  const NotifyDecision({
    required this.post,
    required this.sound,
    required this.banner,
    required this.includePreview,
    required this.countsAsUnread,
    required this.reason,
  }) : assert(reason != '', 'every decision names the rule behind it');

  final bool post;
  final bool sound;
  final bool banner;
  final bool includePreview;
  final bool countsAsUnread;

  /// Which rule produced this, from [NotifyReason].
  final String reason;

  /// True when the device is asked to make any noise at all.
  ///
  /// The question the user actually cares about, and the one that decides
  /// whether they keep notifications switched on.
  bool get alerts => sound || banner;

  @override
  String toString() =>
      'NotifyDecision(post: $post, sound: $sound, '
      'banner: $banner, preview: $includePreview, unread: $countsAsUnread, '
      'why: $reason)';
}

/// Who somebody is, as far as a notification cares.
///
/// A [nickname] and a [jid] rather than one string because in a room the nick is
/// the name people use and the JID is an address; a notification that shows the
/// address in a room reads as a stranger, and one that shows a nick in a 1:1
/// reads as a stranger too.
class NotifyIdentity {
  const NotifyIdentity({required this.jid, this.nickname});

  final String jid;

  /// The name this person goes by in a group, or null outside one.
  final String? nickname;

  /// The name to put in a notification.
  ///
  /// Falls back to the localpart rather than to empty, so a room member whose
  /// nick we have not seen is still attributable. A notification naming nobody is
  /// a message with no context, and the first thing the user does with a message
  /// with no context is ignore it.
  String get label {
    final nick = nickname?.trim() ?? '';
    return nick.isNotEmpty ? nick : localpart;
  }

  /// Everything before the `@`, and before any `/resource`.
  String get localpart {
    final at = jid.indexOf('@');
    final bare = at > 0 ? jid.substring(0, at) : jid;
    final slash = bare.indexOf('/');
    return slash > 0 ? bare.substring(0, slash) : bare;
  }

  @override
  String toString() => 'NotifyIdentity($jid, $nickname)';
}

/// Everything the rules are allowed to look at.
///
/// Every field defaults to false, and that is deliberate: an all-false input is
/// a plain message in a plain conversation, which is the answer the user
/// expects. The failure to design against is a policy that treats "we don't
/// know" as "don't interrupt", because that turns every missing value — a
/// conversation row not read yet, a field a future caller forgets — into a
/// client that never says anything and looks like it is working.
class NotifyPolicy {
  const NotifyPolicy({
    required this.sender,
    required this.me,
    this.body = '',
    this.muted = false,
    this.alwaysNotify = true,
    this.archived = false,
    this.pinned = false,
    this.isGroup = false,
    this.carbon = false,
    this.undecryptable = false,
    this.blocked = false,
    this.appInForeground = false,
    this.reading = false,
    this.privateMessage = false,
  });

  /// Who wrote it.
  final NotifyIdentity sender;

  /// Who we are, needed only to recognise a mention.
  final NotifyIdentity me;

  /// The message text, or empty when [undecryptable].
  final String body;

  /// Conversations "notify never": silence even when highlighted.
  final bool muted;

  /// Conversations `alwaysNotify`. When false, only [mentionsUser] alerts.
  ///
  /// Callers should force this true for 1:1 chats — highlight-only is a
  /// room setting.
  final bool alwaysNotify;

  /// The user moved this conversation out of the main list.
  final bool archived;

  /// The user pinned this conversation to the top of the list.
  ///
  /// Carried and read by nobody, on purpose — see `decide`. It is here so that
  /// a caller passing it gets it refused in one tested place rather than
  /// quietly discovering that pinning re-enables anything.
  final bool pinned;

  /// A room, so the sender is one of several and must be named in the preview.
  final bool isGroup;

  /// A copy of our own message from another of our devices (XEP-0280).
  final bool carbon;

  /// We could not open it, so [body] is not the message.
  final bool undecryptable;

  /// The sender is on the block list.
  final bool blocked;

  /// The app is in front of the user.
  final bool appInForeground;

  /// The user is looking at *this* conversation.
  ///
  /// Caller-supplied because only the UI knows: "this message arrived while the
  /// chat page was on top" is not a fact derivable from the message or from the
  /// lifecycle alone, and a module that guessed it would be a module that has to
  /// be taken on trust at exactly the point where being wrong buzzes.
  final bool reading;

  /// A private message inside a MUC (Conversations `wasHighlightedOrPrivate`).
  ///
  /// Counts as a highlight even with no nick in the body: the message was
  /// addressed to us alone.
  final bool privateMessage;
}

/// Conversations `NotificationService.generateNickHighlightPattern`.
///
/// Nick after start-of-string or whitespace; optional `@` (composer habit);
/// then whitespace, end, or punctuation. Case-insensitive.
RegExp nickHighlightPattern(String nick) {
  final escaped = RegExp.escape(nick);
  return RegExp(
    '(?<=(^|\\s))@?$escaped(?=\\s|\$|\\p{P})',
    caseSensitive: false,
    unicode: true,
  );
}

/// Names that count as "us" for a nick highlight (room nick + bare localpart).
Set<String> highlightNamesFor({String? nickname, String? meJid}) {
  final names = <String>{
    if (nickname != null) nickname.trim(),
    if (meJid != null && meJid.isNotEmpty) NotifyIdentity(jid: meJid).localpart,
  }..removeWhere((n) => n.isEmpty);
  return names;
}

/// Whether [body] addresses any of [names] under [nickHighlightPattern].
bool bodyHighlightsNick(String body, Iterable<String> names) {
  if (body.isEmpty) return false;
  for (final name in names) {
    if (name.isEmpty) continue;
    if (nickHighlightPattern(name).hasMatch(body)) return true;
  }
  return false;
}

/// Whether [policy]'s message addresses the user (nick highlight or MUC PM).
///
/// Matching follows Conversations' highlight rule (see [nickHighlightPattern]),
/// plus our localpart when the room has no nick for us yet. Only ever true in
/// a group: in a 1:1 the mute *is* the setting for that person.
///
/// False for undecryptable bodies — we must not take mention decisions on text
/// we could not open.
bool mentionsUser(NotifyPolicy policy) {
  if (policy.undecryptable) return false;
  if (!policy.isGroup) return false;
  if (policy.privateMessage) return true;
  return bodyHighlightsNick(
    policy.body,
    highlightNamesFor(nickname: policy.me.nickname, meJid: policy.me.jid),
  );
}

/// Decides what an inbound message should do.
///
/// Order matters and is the policy:
///
///   1. [NotifyPolicy.blocked] — over everything, including the mention
///      override below. The one guarantee `blocking.dart` makes is that a
///      blocked sender cannot make this device act as a reader or a notifier on
///      their behalf, and a mention is text *they* wrote. Letting it through
///      would mean blocking is defeated by anyone who knows the user's name.
///   2. [NotifyPolicy.carbon] — before the mention override too, because the
///      text in a carbon is text this user wrote. A self-mention is not
///      something that happened in the world.
///   3. [NotifyPolicy.reading] — they are looking at it.
///   4. [NotifyPolicy.archived] — before the mention override, and this is the
///      one asymmetry between archive and mute worth stating: archiving is a
///      claim about a *room* and muting is a claim about a *person*. A room has
///      dozens of senders the user did not choose and cannot mute one by one, so
///      the only lever is to put it away — and a mention should not turn that
///      into a stream of pings from the whole membership.
///   5. [NotifyPolicy.muted] — Conversations "notify never"; no highlight
///      override (unlike highlight-only below).
///   6. Highlight-only (`!alwaysNotify`) — silent unless [mentionsUser].
///   7. [NotifyPolicy.appInForeground] — before the undecryptable rule,
///      because "the app is open" is about the phone and "we could not open the
///      message" is about the message. The foreground wins, or the user is told
///      about a message sitting in the conversation they are looking at.
///   8. [NotifyPolicy.undecryptable] — announce, never describe.
///   9. Otherwise notify.
///
/// Every decision that alerts also counts as unread, because the badge is not a
/// notification: it is the only record that a message is waiting, and one that
/// buzzes while showing no badge reads as read.
NotifyDecision decide(NotifyPolicy policy) {
  // Pinned is deliberately unread. It is a statement about where a conversation
  // sits in a list, not about wanting to be interrupted; a mute that a pin could
  // undo is not a mute, and the user who set one would have no way to make it
  // stick.
  // Blocked before carbon, because a block is the security-relevant fact and
  // carbon is a UX one.
  //
  // A stanza arriving from someone the user blocked must report *that*, whatever
  // else is true of it: it is the one condition here that means a message was
  // suppressed on purpose, and [NotifyDecision.reason] is what a bug report will
  // quote. "carbon" would point at a code path, "blocked" points at the thing the
  // user did.
  //
  // Both produce the same silence, so nothing observable depends on the order —
  // which is exactly why the two rules needed one direction chosen and stated
  // rather than each test asserting its own.
  if (policy.blocked) return _silent(NotifyReason.blocked);
  if (policy.carbon) return _silent(NotifyReason.carbon);
  if (policy.reading) return _silent(NotifyReason.readingThisConversation);
  if (policy.archived) return _silent(NotifyReason.archived);

  // Conversations three-way: never / highlight-only / all.
  // "Never" is absolute — a nick in the body must not defeat it.
  // Unread still counts: mute is about the shade, not the badge.
  if (policy.muted) {
    return const NotifyDecision(
      post: false,
      sound: false,
      banner: false,
      includePreview: false,
      countsAsUnread: true,
      reason: NotifyReason.muted,
    );
  }

  final mentioned = mentionsUser(policy);
  if (!policy.alwaysNotify && !mentioned) {
    return const NotifyDecision(
      post: false,
      sound: false,
      banner: false,
      includePreview: false,
      countsAsUnread: true,
      reason: NotifyReason.notHighlighted,
    );
  }

  // Foreground still counts unread. A message that arrives while the user is
  // reading a different conversation has to be counted somewhere, and if it is
  // not counted here then closing the app looks identical to never having
  // received it.
  if (policy.appInForeground) {
    return const NotifyDecision(
      post: false,
      sound: false,
      banner: false,
      includePreview: false,
      countsAsUnread: true,
      reason: NotifyReason.appInForeground,
    );
  }

  // A message we could not open still gets the notification: not arriving at
  // all would be the worse lie, since the user would open the app, find an
  // unreadable row they were never told about, and conclude the message was
  // lost. What it must never get is the text — see [previewText].
  if (policy.undecryptable) {
    return const NotifyDecision(
      post: true,
      sound: true,
      banner: true,
      includePreview: false,
      countsAsUnread: true,
      reason: NotifyReason.undecryptable,
    );
  }

  return NotifyDecision(
    post: true,
    sound: true,
    banner: true,
    includePreview: true,
    countsAsUnread: true,
    reason: mentioned && !policy.alwaysNotify
        ? NotifyReason.highlighted
        : NotifyReason.incoming,
  );
}

/// Everything suppressed: no shade entry, no noise, no banner, no badge.
NotifyDecision _silent(String reason) => NotifyDecision(
  post: false,
  sound: false,
  banner: false,
  includePreview: false,
  countsAsUnread: false,
  reason: reason,
);

/// One decided notification, ready for whatever mechanism this platform needs.
///
/// The last piece of the split between policy and mechanism: the decision and
/// the text are computed together and cannot be posted apart. A caller that
/// ignored [NotifyDecision.includePreview] would put a message body in front of
/// whoever is holding the phone; here the line to show is already absent, so
/// there is nothing to leak by forgetting a flag.
class NotifyRequest {
  const NotifyRequest({
    required this.chatJid,
    required this.sender,
    required this.preview,
    required this.decision,
  });

  /// The conversation this belongs to.
  final String chatJid;

  /// Who to attribute it to.
  final NotifyIdentity sender;

  /// The one line to show, or null when nothing may be said.
  ///
  /// Null rather than an empty string or a placeholder: "do not show the text"
  /// must not be something a mechanism has to remember to do.
  final String? preview;

  final NotifyDecision decision;
}

/// What to post for [policy], or null when nothing should be posted.
///
/// Calls [decide] itself rather than taking a decision, so that a caller cannot
/// end up posting one message's decision with another message's text. The price
/// is a second call to a pure function, which is cheaper than the bug.
///
/// Null rather than a request carrying `post: false`, so that "post this" and
/// "do nothing" are different values rather than one value read two ways.
NotifyRequest? notificationFor(NotifyPolicy policy, {required String chatJid}) {
  final decision = decide(policy);
  if (!decision.post) return null;
  return NotifyRequest(
    chatJid: chatJid,
    sender: policy.sender,
    preview: decision.includePreview ? previewText(policy) : null,
    decision: decision,
  );
}

/// The one line a notification shows.
///
/// Safe to call for any input, including the ones [decide] refused. That is the
/// point: the decision is the thing that decides whether anyone sees this, and
/// the text is the thing that ends up in front of whoever is holding the phone,
/// so the text must be wrong in the safe direction even when the decision was
/// ignored. A caller that ignores `post` and renders this anyway gets the
/// contentless constant, not a message body.
///
/// Three rules:
///
///   * An undecryptable message gets [kNoPreviewText]. Never the placeholder
///     "Unable to decrypt" — that string is a description of *our* failure, and
///     the store already keeps it out of search for the same reason it must stay
///     out of a notification (`searchMessages` excludes error rows so nobody goes
///     looking for words nobody wrote). A notification that reports a decryption
///     failure also tells anyone who picks the phone up that this conversation
///     holds something this device could not open, which is a fact about the
///     user's contacts that they did not choose to publish. Never any part of
///     the stored body either: when we could not open it, the body is empty, and
///     a rule that said "empty body, so show the text" would be a rule that
///     starts leaking the day an undecryptable row keeps stale text from a
///     previous decryption attempt.
///   * A group prefixes the sender, because in a room "see you at 8" is a
///     different message depending on who said it, and a preview without the
///     name makes the user open the app to find out who.
///   * Everything else is the body on one line, cut to [kMaxPreviewLength].
///
/// A body with no text is not an empty message — it is a message whose text is
/// not what the notification shows, which is what an image looks like here. It
/// gets [kNoPreviewText] rather than an empty string, because a notification
/// with no body reads as a failure to arrive, which is the confusion this file
/// exists to prevent.
String previewText(NotifyPolicy policy) {
  if (policy.blocked) {
    // The only way a body exists for a blocked sender is that the block was
    // lifted or bypassed, and neither of those is a reason to put their words
    // on a lock screen. [decide] already posts nothing; this is the backstop
    // for a caller that ignored it.
    return kNoPreviewText;
  }
  if (policy.undecryptable) return kNoPreviewText;
  if (policy.carbon) return kNoPreviewText;

  final body = _oneLine(policy.body);
  if (body.isEmpty) return kNoPreviewText;
  // The cap is applied to the finished line rather than to the body, or a long
  // message in a room with a long nickname would overflow the one line this
  // whole function exists to produce.
  if (!policy.isGroup) return _cap(body);
  final who = _cap(policy.sender.label);
  return who.isEmpty ? _cap(body) : _cap('$who: $body');
}

/// Collapses [raw] to a single line.
///
/// Whitespace is collapsed rather than stripped so a message that was two lines
/// of a quote reads as one line instead of being silently truncated to its
/// first word by a notification that only has room for one.
String _oneLine(String raw) => raw.replaceAll(RegExp(r'\s+'), ' ').trim();

String _cap(String flat) {
  if (flat.length <= kMaxPreviewLength) return flat;
  return '${flat.substring(0, kMaxPreviewLength - 1).trimRight()}…';
}
