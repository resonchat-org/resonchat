// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Publish lists: the ignore list and the priority list.
//
// Two PubSub nodes on our own account carry statements about contacts, and both
// are written by our other devices as well as by us:
//
//   * the ignore list — one item per bare JID: "do not show me this person".
//   * the priority list — one item per bare JID *and subscription state*:
//     "while we are in this state with them, they are worth this much".
//
// No Standards Track XEP covers this pair, so the namespaces below are the
// whole contract. Nothing here may be relaxed on the strength of a spec version
// that does not exist.
//
// This file is the value and decision layer only: no storage, no stanzas, no
// widgets, no imports at all. It answers the three questions the rest of the
// app asks anyway — is this contact ignored, what should the roster show for
// them, and what do we send to the server — so that the answers are decided
// once and tested, rather than re-derived per call site where a slightly
// different reading creeps in.
//
// The half that matters more is what this file refuses to claim:
//
//   * An ignore-list entry is not the blocking guarantee. `xmpp/blocking.dart`
//     is. This list is what our other devices publish, and a client that
//     treated it as its security boundary would quietly lose the protection on
//     any server that does not implement it.
//   * A priority entry never hides anybody, however well it matches.
//   * Nothing here retracts a publish-list item it has not observed.

/// The PubSub node holding the ignore list.
const String kIgnoreNode = 'urn:xmpp:publish:0';

/// The PubSub node holding the priority list.
///
/// Named by the same de-facto convention as [kIgnoreNode] (`publish:0` →
/// `priorities:0`), which is what the other clients using these lists publish
/// to. A constant rather than a literal in the connection layer so that a
/// server which disagrees is a one-line change in one place, not a search.
const String kPriorityNode = 'urn:xmpp:priorities:0';

/// The access model both nodes use: anyone may read them, only we may write.
///
/// The whole reason the ignore list can exist at all. A list our other devices
/// publish and every contact could publish into would be a list nobody can
/// trust, and the response to an untrustworthy ignore list is to ignore it —
/// which means the protection is gone exactly where it is wanted.
const String kPublishersAccessModel =
    'http://jabber.org/protocol/pubsub#publishers';

/// The RFC 6121 subscription states a publish list can name.
///
/// Defined here rather than imported: this module has no dependencies, and the
/// one thing a publish list does with a subscription state is compare it, which
/// a four-value enum is enough for. A string comparison would make `'Both'`
/// and `'both'` two different instructions.
enum SubscriptionState {
  none('none'),
  to('to'),
  from('from'),
  both('both');

  const SubscriptionState(this.wire);

  /// The value as it appears on the wire.
  final String wire;

  static final Map<String, SubscriptionState> _byWire = {
    for (final state in SubscriptionState.values) state.wire: state,
  };

  /// The state [raw] names, or null when it names none we know.
  ///
  /// Total on purpose, because [raw] arrives from a client we do not control:
  /// throwing on one attribute of one item would take down the handling of an
  /// entire push. Null also keeps a corrupt value from *becoming* [none], which
  /// is a meaningful state on the priority node and the one a broken entry
  /// would most plausibly be mistaken for — a priority entry for `none` means
  /// "while we have no subscription", not "we could not read the attribute".
  static SubscriptionState? fromWire(String? raw) {
    if (raw == null) return null;
    return _byWire[raw.trim().toLowerCase()];
  }
}

/// [jid] reduced to the form a publish list keys on, or null when it is not
/// one.
///
/// Four normalisations, each of which is a rule somebody can otherwise break
/// by accident:
///
///   * The resource is dropped. `juliet@example.org/phone` and
///     `juliet@example.org` are the same contact, and a list that treated them
///     as two would be defeated by changing device.
///   * The whole JID is case-folded, localpart included. Domain folding is
///     forced by the specs; localpart folding is PRECIS UsernameCaseMapped, and
///     a server that hosts two accounts differing only by localpart case is
///     already outside what the addressing rules permit. The alternative is a
///     list that a contact escapes by sending from `Juliet@example.org`.
///   * A leading `xmpp:` is stripped, because that is how a paste arrives and
///     an address we cannot key is an address we cannot act on.
///   * Anything left that cannot be a JID gets no key at all.
///
/// A domain-only JID is a legal key: ignoring a whole service is a thing users
/// do, and a normaliser that rejected it would write an item nothing can then
/// match.
///
/// Deliberately not the same function as `mam_prefs.dart`'s `bareJid`, and the
/// difference is the point. That one must fail *open* — an address it cannot
/// make sense of still gets a key, because dropping an override would hand that
/// conversation back to the default and re-enable archiving for exactly the
/// person the user switched it off for. This one fails *closed*: an entry with
/// no key is an instruction we cannot enforce, and a list that carries one
/// anyway is a list claiming to ignore somebody while showing them. Two
/// normalisers, opposite failure modes, both correct.
String? publishJidKey(String jid) {
  var value = jid.trim();
  if (value.toLowerCase().startsWith('xmpp:')) {
    value = value.substring(5).trim();
  }
  final slash = value.indexOf('/');
  if (slash >= 0) value = value.substring(0, slash);
  if (value.isEmpty) return null;
  if (value.contains(RegExp(r'''[\s<>"'&]'''))) return null;
  // At most one `@`, and not at either end: `example.org` is a bare JID but
  // `@example.org` and `a@b@c` are the shapes a truncated or doubled address
  // arrives in.
  final at = value.indexOf('@');
  if (at == 0 || at == value.length - 1) return null;
  if (at >= 0 && value.indexOf('@', at + 1) >= 0) return null;
  return value.toLowerCase();
}

String? _displayName(String? raw) {
  final value = raw?.trim();
  return (value == null || value.isEmpty) ? null : value;
}

/// One item on the ignore-list node.
///
/// The key is the bare JID and nothing else. Everything else on the item is
/// decoration that another client reads.
class IgnoreEntry {
  const IgnoreEntry({required this.jid, this.displayName, this.subscription});

  /// Reads one item, or null when its key is not a JID we can act on.
  ///
  /// An unreadable name or subscription costs only the decoration: the entry
  /// still ignores. Discarding the whole item because an *optional* attribute
  /// was malformed would un-ignore somebody because a client we do not control
  /// wrote a spare attribute, which is not a trade this list makes.
  static IgnoreEntry? fromWire(
    String rawJid, {
    String? name,
    String? subscription,
  }) {
    final jid = publishJidKey(rawJid);
    if (jid == null) return null;
    return IgnoreEntry(
      jid: jid,
      displayName: _displayName(name),
      subscription: SubscriptionState.fromWire(subscription),
    );
  }

  /// The bare JID this entry is about.
  ///
  /// Pass through [publishJidKey] first when building an entry by hand from
  /// anything user-supplied; [fromWire] does it for anything off the wire.
  final String jid;

  /// A name to show instead of the JID. Never a key.
  final String? displayName;

  /// The state the publishing client last saw us in with them.
  ///
  /// Descriptive, and never consulted by any decision in this file. It is kept
  /// so a contact manager can say why it thinks somebody is ignored; see
  /// [rosterViewFor] for why it must not narrow anything.
  final SubscriptionState? subscription;

  /// The PubSub item id: the bare JID, unchanged.
  String get itemId => jid;

  @override
  String toString() => 'IgnoreEntry($jid, name: $displayName)';
}

/// One item on the priority-list node.
///
/// The key is the *pair* (jid, subscription state), which is why an item id
/// carries the state after a slash and why the two lists' patches cannot be
/// merged into one.
class PriorityEntry {
  const PriorityEntry({required this.jid, this.displayName, this.subscription});

  /// Reads one item from its fields, or null when its key is unreadable.
  ///
  /// The key is the pair, not the JID alone, so this is where an unrecognised
  /// subscription state costs the whole entry — see below.
  static PriorityEntry? fromWire(
    String rawJid, {
    String? name,
    String? subscription,
  }) {
    final jid = publishJidKey(rawJid);
    if (jid == null) return null;
    // An absent or empty value names no state. Any other value we do not
    // recognise invalidates the whole entry, because the state is part of the
    // key: reading it as "names no state" would widen the entry to every state,
    // and a corrupt attribute must not be handed the broadest instruction on
    // offer.
    if (subscription != null &&
        subscription.isNotEmpty &&
        SubscriptionState.fromWire(subscription) == null) {
      return null;
    }
    return PriorityEntry(
      jid: jid,
      displayName: _displayName(name),
      subscription: SubscriptionState.fromWire(subscription),
    );
  }

  /// Reads an item id of the form `<jid>[/<subscription>]`.
  ///
  /// Split at the *last* slash, not the first: the part in front of it is still
  /// a JID that may carry a resource, and taking everything after the last
  /// slash is what leaves `juliet@example.org/phone/both` readable.
  static PriorityEntry? fromItemId(String itemId, {String? name}) {
    final slash = itemId.lastIndexOf('/');
    if (slash < 0) return fromWire(itemId, name: name);
    return fromWire(
      itemId.substring(0, slash),
      name: name,
      subscription: itemId.substring(slash + 1),
    );
  }

  /// The bare JID this entry is about.
  final String jid;

  /// A name to show instead of the JID. Never a key.
  final String? displayName;

  /// The state the entry is scoped to, or null when it names none.
  final SubscriptionState? subscription;

  /// The PubSub item id, which is why a state change is not an edit.
  String get itemId =>
      subscription == null ? jid : '$jid/${subscription!.wire}';

  /// Whether this entry's priority applies while the contact is in [state].
  ///
  /// An entry that names no state applies to every state, which is the only
  /// reading that lets a client publish a bare "they are a priority" without
  /// enumerating states. An entry whose state we could not read never gets
  /// this far — [fromWire] drops it — so "applies to nothing" and "applies to
  /// all" cannot be confused.
  bool appliesTo(SubscriptionState? state) =>
      subscription == null || subscription == state;

  @override
  String toString() => 'PriorityEntry($itemId, name: $displayName)';
}

/// Both publish lists as they are known right now.
///
/// Held as one value because the questions below are about both lists at once:
/// which one wins for a contact is not a question either list can answer alone.
class PublishLists {
  const PublishLists({
    required this.ignore,
    required this.priorities,
    required this.complete,
  });

  /// Both nodes were read and hold nothing: the user publishes no lists.
  const PublishLists.empty()
    : ignore = const [],
      priorities = const [],
      complete = true;

  /// Neither node could be read.
  ///
  /// Separate from [PublishLists.empty] because the two must never be
  /// interchangeable, even though they answer alike: "we looked and found
  /// nothing" is a fact about the user and "we did not look" is a fact about
  /// us, and only the first is worth telling the user.
  const PublishLists.unread()
    : ignore = const [],
      priorities = const [],
      complete = false;

  final List<IgnoreEntry> ignore;
  final List<PriorityEntry> priorities;

  /// True when both nodes were read this session.
  ///
  /// It does not gate any answer below: a list we could not read still answers,
  /// permissively. It exists so a caller can tell the difference between "this
  /// roster is confident" and "this roster is what we happened to be able to
  /// read", which is the difference between drawing an empty list and drawing a
  /// wrong one.
  final bool complete;
}

/// Which list a contact belongs in.
enum PublishBucket {
  /// Named on neither list — an ordinary contact.
  contact,

  /// Named on the priority list.
  priority,

  /// Named on the ignore list.
  ignored,
}

/// Which list [jid] belongs in.
///
/// A contact named on both lists resolves to [PublishBucket.ignored]. The two
/// lists are written by our other devices as well as by us and can disagree;
/// the safest reading is the one where we do least on the contact's behalf.
///
/// The alternative — "whichever was published most recently wins" — hands the
/// answer to clock skew between our own devices, and on a tie to whichever
/// stanza arrived second, which is not a rule anybody could have chosen.
PublishBucket bucketFor(PublishLists lists, String jid) {
  final bare = publishJidKey(jid);
  // An address we cannot read is on neither list. Answering `contact` rather
  // than `ignored` is the permissive direction, and it is right here: a caller
  // that reaches this function with an unreadable address has a bug upstream,
  // and answering `ignored` would turn that bug into an empty roster.
  if (bare == null) return PublishBucket.contact;
  if (_ignored(lists, bare)) return PublishBucket.ignored;
  // By JID alone, with no regard for the state: the question is which list
  // names this *person*, and whether their entry currently applies is a
  // separate question with a separate answer.
  for (final entry in lists.priorities) {
    if (entry.jid == bare) return PublishBucket.priority;
  }
  return PublishBucket.contact;
}

/// What the roster should show for one contact.
enum RosterView {
  /// Not shown and not notified about: the ignore list names them.
  hidden,

  /// An ordinary contact, shown.
  listed,

  /// Shown, and the priority list names this exact subscription state — a
  /// contact the user chose to hear from.
  listedFirst,
}

/// What the roster should show for [jid], who is currently in [subscription].
///
/// The subscription state is part of the question because the priority list is
/// scoped by it and the ignore list is not. An ignore entry's
/// [IgnoreEntry.subscription] is deliberately never consulted: if it were, a
/// contact ignored while pending would reappear the instant they became a
/// mutual contact — a list that stops applying at exactly the moment it is
/// needed.
///
/// A priority entry naming a *different* state does not demote anybody either.
/// Those entries are written against the state their client saw when it
/// published, so they go stale the moment either side accepts a request; hiding
/// on a mismatch would make the one conversation the user just fixed disappear,
/// with nothing in the interface to say why.
RosterView rosterViewFor(
  PublishLists lists,
  String jid, {
  SubscriptionState? subscription,
}) {
  final bare = publishJidKey(jid);
  // Same permissive default as [bucketFor]: an unreadable address is not an
  // instruction to hide somebody.
  if (bare == null) return RosterView.listed;
  if (_ignored(lists, bare)) return RosterView.hidden;
  for (final entry in lists.priorities) {
    if (entry.jid == bare && entry.appliesTo(subscription)) {
      return RosterView.listedFirst;
    }
  }
  return RosterView.listed;
}

bool _ignored(PublishLists lists, String bare) {
  for (final entry in lists.ignore) {
    if (entry.jid == bare) return true;
  }
  return false;
}

/// The item ids to publish and to retract on one publish-list node.
///
/// Per node and never for both at once: a bare JID is an item id on *both*
/// nodes, so a patch that did not say which node an id belonged to could not be
/// sent. The caller retracts before it publishes, so that a state change from
/// `jid/both` to `jid` is never briefly both.
class PublishPatch {
  const PublishPatch({required this.toAdd, required this.toRemove});

  /// Item ids to publish.
  final Set<String> toAdd;

  /// Item ids to retract.
  final Set<String> toRemove;

  bool get isEmpty => toAdd.isEmpty && toRemove.isEmpty;

  /// True when the patch only takes things away.
  ///
  /// Worth naming because it is the shape that loses data, and to a caller that
  /// only checks [isEmpty] it is indistinguishable from a patch that removed
  /// nothing.
  bool get isRetractOnly => toAdd.isEmpty && toRemove.isNotEmpty;

  @override
  String toString() => 'PublishPatch(add: $toAdd, remove: $toRemove)';
}

/// The patch that makes the ignore-list node hold [desired].
///
/// [published] is what is on the node, or **null when the node was not read** —
/// which is not the same as an empty list. See [_patch].
PublishPatch ignorePatch({
  required Iterable<IgnoreEntry> desired,
  required Iterable<IgnoreEntry>? published,
}) {
  return _patch(
    desired: desired.map((entry) => entry.itemId),
    published: published?.map((entry) => entry.itemId),
  );
}

/// The patch that makes the priority-list node hold [desired].
///
/// A subscription-state change shows up here as a retract of the old id and a
/// publish of the new one, because the state is part of the id and there is no
/// such thing as editing one item id into another.
PublishPatch priorityPatch({
  required Iterable<PriorityEntry> desired,
  required Iterable<PriorityEntry>? published,
}) {
  return _patch(
    desired: desired.map((entry) => entry.itemId),
    published: published?.map((entry) => entry.itemId),
  );
}

/// Compares by item id alone.
///
/// Not by payload: republishing because a display name moved would fight our
/// own other devices over a field nobody here acts on, and the write would
/// overwrite whatever name they published with ours. The id is the entry.
PublishPatch _patch({
  required Iterable<String> desired,
  required Iterable<String>? published,
}) {
  final want = desired.toSet();
  if (published == null) {
    // We did not look, so we may not take anything away. A retract for an item
    // we never observed is a lost update against whichever of our devices
    // published it in the meantime, and prosody answers `item-not-found` for
    // one — a refusal a caller cannot tell from a write that failed. Publishing
    // the whole desired set is the only action that converges on an unknown
    // server state; doing nothing is what leaves it wrong.
    return PublishPatch(toAdd: want, toRemove: const <String>{});
  }
  final have = published.toSet();
  // Both differences run over the two sets, so no id can appear in both halves
  // and the patch can never undo its own publish.
  return PublishPatch(
    toAdd: want.difference(have),
    toRemove: have.difference(want),
  );
}
