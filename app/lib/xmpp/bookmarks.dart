// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Message bookmarks (XEP-0333, PEP Native Bookmarks).
//
// A bookmark answers one question: which conversations do I want to be in when
// I open this app. It lives on the user's own server, so it is the only part of
// this client's state that is shared with the user's *other* devices rather
// than merely cached on this one.
//
// Three consequences, and every decision below follows from one of them:
//
//   * The list is published **whole**. XEP-0333 keeps every bookmark inside a
//     single PubSub item (`storage:bookmarks`, item `current`) rather than one
//     item each, so there is no "publish one room" and no retract-to-delete —
//     a removal is a republish without that entry. That is why this module
//     computes a *plan* and the caller turns it into exactly one stanza.
//   * The list belongs to the user, not to us. A diff that believes it knows
//     the whole list can delete every room they have, and the one time it does
//     that is the time it was wrong: a reinstall, before the server's copy has
//     been read. Hence [BookmarkIntent], which makes "I know the whole list" an
//     assertion the caller has to state.
//   * Bookmarks arrive from clients that are not us and carry fields we have
//     not modelled. Rewriting one must not drop them — and must not be *caused*
//     by them either, or two devices republish the same room at each other for
//     as long as both are signed in.

/// The namespace of a version-1 bookmark payload, and the feature a service
/// advertises for it.
const String bookmarksNamespace = 'urn:xmpp:bookmarks:1';

/// The same string as [bookmarksNamespace], kept separately because they answer
/// different questions — one goes in the payload, the other in a disco identity
/// — and a reader should not have to know that they happen to coincide.
const String bookmarksFeature = 'urn:xmpp:bookmarks:1';

/// The `storage:bookmarks` form of the feature, for a service that pushes
/// changes made by our own other devices.
const String bookmarksNotifyFeature = 'storage:bookmarks+notify';

/// The PubSub node the list lives on.
///
/// Not the namespace: the namespace says what a payload is, the node says
/// *which list* this is, and only the node decides what a push reaches. Sending
/// the namespace as the node is the single most common way of ending up with a
/// node no client ever looks at, so the two are separate constants.
const String bookmarksNode = 'storage:bookmarks';

/// The one item every bookmark is stored in.
///
/// Part of XEP-0333's shape, and the reason a removal is a republish rather
/// than a retract: there is a single item, so there is nothing to retract.
/// (XEP-0402 later changed the model to one item per bookmark, addressed by
/// bare JID. If that ever gets implemented, [Bookmark.key] is already the item
/// id it would use — which is why the identity is folded into a field of its
/// own rather than derived on demand.)
const String bookmarksItemId = 'current';

/// `pubsub#access_model` for the bookmark node: `whitelist`.
///
/// A bookmark list is not merely private, it is a map of somebody's social
/// life — it names which rooms they read. The other value PEP offers,
/// `presence`, hands the list to any contact who asks, so a roster member with
/// a stanza subscription could read it.
const String bookmarksAccessModel = 'whitelist';

/// `pubsub#max_items`: `max`, never a count.
///
/// A fixed cap drops the *oldest* bookmark of a user with more rooms than the
/// cap, and the only symptom is that one of their rooms stops opening on a new
/// device. The list is small and belongs to one person.
const String bookmarksMaxItems = 'max';

/// `pubsub#send_last_published_item`: `never`.
///
/// Set once, when the node is created, per XEP-0333 §5.1. With the server's
/// default the full list is pushed to every resource of ours that appears,
/// which on a phone that wakes hourly is the same list of rooms delivered
/// hundreds of times a day.
const String bookmarksSendLastPublishedItem = 'never';

/// The `pubsub#owner` namespace, for configuring a node we own.
const String pubsubOwnerXmlns = 'http://jabber.org/protocol/pubsub#owner';

/// The form type of a node-configuration submit.
const String pubsubNodeConfigFormType =
    'http://jabber.org/protocol/pubsub#node_config';

// No publish-time access model constant, on purpose. `access_model` belongs to
// the node's configuration and is set once by whoever creates the node;
// carrying it on every publish re-configures a node that already exists, and a
// wider value than `whitelist` would silently make every room the user reads
// visible to their roster.

/// A XEP-0333 address: `xmpp:room@conference.example.org?join`.
///
/// Two jobs and no more. It turns a pasted string, a decoded QR code or a
/// stanza from another client into something we can store, and it turns that
/// back into a string without losing the parts real clients put there.
class BookmarkUri {
  const BookmarkUri._({
    required this.jid,
    required this.key,
    required this.join,
    required this.qr,
    required this.raw,
  });

  /// The bare JID, as it was written.
  ///
  /// Casing preserved on purpose: this is the string other clients display and
  /// the one the user typed, so folding it here would be a silent edit of
  /// somebody else's data. Folding belongs to [key].
  final String jid;

  /// [jid] casefolded — this address's identity.
  ///
  /// Not decoration. The identity decides which bookmark this *is*, so
  /// `xmpp:MyRoom@x` and `xmpp:myroom@x` have to collide. If they did not, one
  /// room would exist in the list twice under two independent auto-join flags,
  /// and it would open or stay closed depending on which copy a client read.
  final String key;

  /// `?join`: the user asked to be *taken to the join*, not to be joined.
  ///
  /// Never stored on a bookmark. It describes one tap; a bookmark describes
  /// every launch after it, and a room the app silently joins itself is not
  /// what was asked for.
  final bool join;

  /// `?qr`: the address is meant to be shown as a QR code rather than opened.
  final bool qr;

  /// The input with its scheme, resource and unmodelled query parameters still
  /// in it.
  ///
  /// [jid] is what we store; this is what the user gave us, kept so an address
  /// we had to reinterpret can still be shown back to them verbatim.
  final String raw;

  static final RegExp _address = RegExp(
    r'''^[^\s"'&,:;/<>@]+@[^\s"'&,:;/<>@]+$''',
  );

  /// Reads [input], or null when it is not an address we can store.
  ///
  /// Null rather than an exception for anything malformed. A bookmark arrives
  /// from a device we do not control and lands in a settings list; a parse
  /// failure there takes down the whole list to lose one entry that was already
  /// unreadable.
  ///
  /// Lenient in four specific places, because in each of them the address is
  /// unambiguous and refusing it costs a real bookmark:
  ///
  ///   * The scheme is optional and case-insensitive. The same address arrives
  ///     as a bare JID inside `<jid>` from the server and as a URI from a
  ///     client; requiring the URI form would reject every bookmark the server
  ///     holds. `im:` is taken as well — it is the older spelling, it still
  ///     turns up in room invitations, and what follows it is the same address.
  ///   * `xmpp://room@…` is accepted although RFC 5122 spells it
  ///     `xmpp:room@…`. It appears in the wild, and being right about the
  ///     standard here only makes those addresses unusable.
  ///   * The resource is dropped rather than rejected. For a room address the
  ///     resource is *our nickname*, which changes every time we rejoin with
  ///     another one, so a bookmark that carried it would stop naming the room.
  ///
  /// Everything else is refused rather than guessed at. A bookmark pointing at
  /// the wrong place is worse than a missing one: the wrong one joins a room
  /// the user never chose, in front of the people in it.
  static BookmarkUri? parse(String? input) {
    if (input == null) return null;
    var text = input.trim();
    if (text.isEmpty) return null;

    for (final scheme in const ['xmpp:', 'im:']) {
      if (text.length >= scheme.length &&
          text.substring(0, scheme.length).toLowerCase() == scheme) {
        text = text.substring(scheme.length);
        if (text.startsWith('//')) text = text.substring(2);
        break;
      }
    }

    // A fragment addresses nothing in XMPP, so it is dropped rather than
    // refused: the address in front of it is usually the usable one, and an
    // actual URL fails the address check below regardless of what follows its
    // '#'.
    final hash = text.indexOf('#');
    if (hash >= 0) text = text.substring(0, hash);

    final mark = text.indexOf('?');
    final query = mark < 0 ? '' : text.substring(mark + 1);
    var address = mark < 0 ? text : text.substring(0, mark);

    final slash = address.indexOf('/');
    if (slash >= 0) address = address.substring(0, slash);

    if (!_address.hasMatch(address)) return null;

    var join = false;
    var qr = false;
    for (final part in query.split('&')) {
      if (part.isEmpty) continue;
      final eq = part.indexOf('=');
      final name = (eq < 0 ? part : part.substring(0, eq)).toLowerCase();
      final value = eq < 0 ? '' : part.substring(eq + 1);
      // A bare `?join` is the form clients actually send; the spelled-out
      // values are here so a link with `?join=false` is not read as a request.
      final on = value.isEmpty || value == 'true' || value == '1';
      if (!on) continue;
      if (name == 'join') join = true;
      if (name == 'qr') qr = true;
    }

    return BookmarkUri._(
      jid: address,
      key: address.toLowerCase(),
      join: join,
      qr: qr,
      raw: input.trim(),
    );
  }

  /// The address back as a `xmpp:` URI.
  ///
  /// Parameter order is fixed — `join` before `qr` — rather than preserved from
  /// the input. The round trip has to be a function of the value: two devices
  /// that bookmarked the same room from the same link must produce the same
  /// string, or every comparison downstream looks like a change and nothing
  /// ever settles.
  String toUriString() {
    final params = <String>[if (join) 'join', if (qr) 'qr'];
    final query = params.isEmpty ? '' : '?${params.join('&')}';
    return 'xmpp:$jid$query';
  }

  @override
  bool operator ==(Object other) =>
      other is BookmarkUri &&
      other.jid == jid &&
      other.join == join &&
      other.qr == qr;

  @override
  int get hashCode => Object.hash(jid, join, qr);

  @override
  String toString() => 'BookmarkUri(${toUriString()})';
}

/// Whether a bookmark is a room or a person.
///
/// Not cosmetic: XEP-0333 stores the two as different elements carrying
/// different attributes, so a bookmark that stops being a conference and
/// becomes a contact is a change the server has to be told about. It is the
/// same bookmark either way — the identity is the JID — so it is an *update*,
/// never a removal followed by an add, because the item id is the identity.
enum BookmarkKind {
  conference(wireTag: 'conference', autoJoinAttribute: 'autojoin'),
  contact(wireTag: 'contact', autoSubmitAttribute: 'auto_submit');

  const BookmarkKind({
    required this.wireTag,
    this.autoJoinAttribute,
    this.autoSubmitAttribute,
  });

  /// The XEP-0333 element name.
  final String wireTag;

  /// The attribute carrying [Bookmark.autoJoin], or null where the XEP has
  /// none.
  final String? autoJoinAttribute;

  /// The attribute carrying [Bookmark.autoSubmit], or null where the XEP has
  /// none.
  final String? autoSubmitAttribute;
}

/// One entry in a user's bookmark list.
class Bookmark {
  /// Normalises [jid] the way [BookmarkUri.parse] does, so a bookmark can never
  /// hold an address we could not publish.
  ///
  /// Throws [ArgumentError] for an address [BookmarkUri.parse] refuses, unlike
  /// that parser. This constructor is handed a string the caller has already
  /// read or typed, so a malformed one is a caller bug — and a bookmark built
  /// with no address would publish as an entry pointing nowhere, which is a
  /// worse failure than a loud error at the call site.
  factory Bookmark({
    required String jid,
    BookmarkKind kind = BookmarkKind.conference,
    String? name,
    bool autoJoin = false,
    bool autoSubmit = false,
    String extensionXml = '',
  }) {
    final uri = BookmarkUri.parse(jid);
    if (uri == null) {
      throw ArgumentError.value(jid, 'jid', 'not a bookmark address');
    }
    return Bookmark._(
      jid: uri.jid,
      key: uri.key,
      kind: kind,
      name: name?.trim() ?? '',
      // Each flag is dropped for the kind the XEP has no attribute for. A flag
      // we wrote into an element that has nowhere to put it would read as set
      // in our own list and be ignored by every other client, which is a
      // setting that looks like it works — worse than one that is visibly
      // absent.
      autoJoin: kind == BookmarkKind.conference && autoJoin,
      autoSubmit: kind == BookmarkKind.contact && autoSubmit,
      extensionXml: extensionXml,
    );
  }

  const Bookmark._({
    required this.jid,
    required this.key,
    required this.kind,
    required this.name,
    required this.autoJoin,
    required this.autoSubmit,
    required this.extensionXml,
  });

  /// The bare address, with the casing it arrived in.
  final String jid;

  /// [jid] folded: what identifies this bookmark, everywhere else.
  final String key;

  final BookmarkKind kind;

  /// The bookmark's own name, or empty when none was given.
  ///
  /// Trimmed once here rather than at display time, so the same bookmark has
  /// the same value whichever client wrote it — `Room ` and `Room` are one
  /// bookmark, not two, and must not make every sync report a change.
  final String name;

  /// Join the room as soon as the app connects.
  final bool autoJoin;

  /// Start a conversation with this contact without asking (XEP-0333
  /// `auto_submit`; clients that show the same idea as a "favourite" contact
  /// call it that).
  final bool autoSubmit;

  /// Every part of the payload the reader did not turn into a field.
  ///
  /// This includes XEP-0333 fields this module does not model — `<nick>`,
  /// `<password>` — as well as foreign `<extensions/>` children, because from
  /// here both are just bytes that must survive a rewrite. The contract on the
  /// reader is therefore "everything you did not model goes in", not "only
  /// `<extensions>` does": a rewrite that drops the nickname of a room the user
  /// joined under a different name sends them back in as a guest.
  final String extensionXml;

  /// What to put on the row.
  ///
  /// A nameless bookmark is ordinary, not broken: XEP-0333 makes the name
  /// optional and plenty of clients write an empty one. An empty string in a
  /// settings list is a row the user cannot recognise, so the fallback is the
  /// local part of the address — the part that says what the thing is — and
  /// [domainPart] is there for the line underneath it.
  String get displayName => name.isNotEmpty ? name : localPart;

  /// `room` in `room@conference.example.org`.
  String get localPart {
    final at = jid.indexOf('@');
    return at < 0 ? jid : jid.substring(0, at);
  }

  /// `conference.example.org`, for the second line of the row.
  String get domainPart {
    final at = jid.indexOf('@');
    return at < 0 ? '' : jid.substring(at + 1);
  }

  /// The address on its own, with no scheme and no parameters.
  ///
  /// Deliberately not a `BookmarkUri`: a bookmark has no query of its own, and
  /// handing back one would invite a caller to store `?join` with it.
  String get uriString => 'xmpp:$jid';

  bool get hasExtensionXml => extensionXml.trim().isNotEmpty;

  /// The same bookmark with some fields changed.
  ///
  /// [extensionXml] is carried over untouched. That is the entire reason it is
  /// opaque: the rewrite that turns auto-join on has to leave `<nick>`,
  /// `<password>` and the foreign children we do not model exactly as it found
  /// them, or a user who bookmarks a password-protected room on a phone and
  /// toggles auto-join on a laptop loses the password.
  Bookmark copyWith({
    BookmarkKind? kind,
    String? name,
    bool? autoJoin,
    bool? autoSubmit,
    String? extensionXml,
  }) {
    final nextKind = kind ?? this.kind;
    return Bookmark._(
      jid: jid,
      key: key,
      kind: nextKind,
      name: name?.trim() ?? this.name,
      // Re-applied through the same rule as the constructor, so changing the
      // kind of a bookmark cannot leave behind a flag the new kind has nowhere
      // to send it.
      autoJoin:
          nextKind == BookmarkKind.conference && (autoJoin ?? this.autoJoin),
      autoSubmit:
          nextKind == BookmarkKind.contact && (autoSubmit ?? this.autoSubmit),
      extensionXml: extensionXml ?? this.extensionXml,
    );
  }

  /// Whether [other] says the same thing about the same address.
  ///
  /// Excludes [extensionXml] and the case of [jid], and both exclusions are
  /// load-bearing. Extension XML is excluded because it is *not ours*: if a
  /// change to it counted as a change here, our diff would republish the
  /// bookmark, dropping what the other device added, which would come back as
  /// a change here again — two devices, republishing one room at each other for
  /// as long as both are signed in, losing a field on every pass. The casing is
  /// excluded for the same reason: `MyRoom@x` and `myroom@x` are one room, and
  /// treating them as two would leave them exchanging identical publishes.
  bool matches(Bookmark other) =>
      key == other.key &&
      kind == other.kind &&
      name == other.name &&
      autoJoin == other.autoJoin &&
      autoSubmit == other.autoSubmit;

  @override
  bool operator ==(Object other) => other is Bookmark && matches(other);

  @override
  int get hashCode => Object.hash(key, kind, name, autoJoin, autoSubmit);

  @override
  String toString() =>
      'Bookmark($jid, $name, ${kind.wireTag}'
      '${autoJoin ? ', autojoin' : ''}${autoSubmit ? ', auto_submit' : ''})';
}

/// How much of the list the caller's desired bookmarks actually are.
///
/// The question exists because "not in the desired list" has two meanings, and
/// they fail in opposite directions: one means the user deleted it, the other
/// means the caller has not looked yet.
enum BookmarkIntent {
  /// The desired list is everything the user has, so a bookmark missing from
  /// it was removed by the user.
  ///
  /// Only true when the list was built from what the user actually sees — the
  /// settings screen, after a successful read of the server's copy.
  replace,

  /// The desired list is only what this caller has seen so far, so a bookmark
  /// missing from it is left exactly as it is.
  ///
  /// The right answer for every path that adds a bookmark without having read
  /// the whole list: a fresh install before its first fetch, a push from
  /// another of our devices, a screen opened from a deep link. Still adds and
  /// still updates; never removes.
  merge,
}

/// One difference between the bookmarks on the server and the ones wanted.
enum BookmarkChange { added, updated, removed }

/// A single operation in a [BookmarkPlan].
class BookmarkOp {
  const BookmarkOp({required this.change, this.before, this.after});

  final BookmarkChange change;

  /// What is there now, or null for [BookmarkChange.added].
  final Bookmark? before;

  /// What it becomes, or null for [BookmarkChange.removed].
  final Bookmark? after;

  /// The bookmark this operation is about.
  Bookmark get bookmark => after ?? before!;

  @override
  String toString() => '$change(${bookmark.jid})';
}

/// What to publish, and what changed to get there.
class BookmarkPlan {
  const BookmarkPlan({
    required this.operations,
    required this.publishList,
    required this.retained,
  });

  /// Every change, additions and updates in the order of [publishList] and then
  /// the removals — see [diffBookmarks] for why removals go last.
  final List<BookmarkOp> operations;

  /// The exact list to put in the payload.
  ///
  /// Not the desired list: in [BookmarkIntent.merge] it is everything that
  /// exists plus everything asked for, because publishing the desired list
  /// verbatim would delete exactly the bookmarks that mode exists to keep.
  final List<Bookmark> publishList;

  /// Bookmarks that were absent from the desired list and were kept anyway.
  ///
  /// Reported rather than silently kept so a caller can say why the row the
  /// user deleted is still in the list.
  final List<Bookmark> retained;

  /// Whether anything is worth publishing.
  ///
  /// A republish that changes nothing still wakes every one of the user's
  /// other devices, and on a two-device account that is a full list of rooms
  /// transferred to answer nothing.
  bool get needsPublish => operations.isNotEmpty;

  List<Bookmark> get added => _with(BookmarkChange.added);

  List<Bookmark> get updated => _with(BookmarkChange.updated);

  List<Bookmark> get removed => _with(BookmarkChange.removed);

  List<Bookmark> _with(BookmarkChange change) => operations
      .where((o) => o.change == change)
      .map((o) => o.bookmark)
      .toList();
}

/// Compares two bookmarks the way [orderBookmarks] puts them in a list.
///
/// A total order, not a preference. The last key — the folded address — is what
/// makes it one, and it is not decoration: Dart's `List.sort` is not stable, so
/// a comparator that calls two bookmarks equal leaves their order to the
/// implementation. Two rooms called `Room` on two services are an ordinary
/// thing to have, and a list that swaps them between opens reads as a bug in
/// the app rather than as the absence of a decision.
int compareBookmarks(Bookmark a, Bookmark b) {
  if (a.autoJoin != b.autoJoin) return a.autoJoin ? -1 : 1;
  if (a.autoSubmit != b.autoSubmit) return a.autoSubmit ? -1 : 1;
  // Folded here and nowhere else: the stored name keeps the casing it arrived
  // with. What this cannot remove is that two clients built against different
  // Unicode versions may fold an exotic letter differently — the address
  // tiebreaker bounds that to two adjacent rows instead of letting the whole
  // list reorder.
  final byName = a.displayName.toLowerCase().compareTo(
    b.displayName.toLowerCase(),
  );
  if (byName != 0) return byName;
  return a.key.compareTo(b.key);
}

/// [bookmarks] in the order they are shown, as a new list.
///
/// Takes anything iterable and returns a list: the caller's own collection is
/// never sorted in place, because a buffer somebody else owns does not get
/// reordered behind their back to make ours tidier.
///
/// Order is derived from the values, never stored and never sent. That is what
/// keeps two devices showing the same bookmarks in the same order without
/// either of them publishing anything: the alternative — remembering a position
/// the user chose — makes every device's copy of the list a thing to
/// reconcile, and the arrangement the user made gets replaced by whichever
/// device published last. What the sort does offer is the one knob that
/// matters and is expressible as a value: [Bookmark.autoJoin] and
/// [Bookmark.autoSubmit] float to the top.
List<Bookmark> orderBookmarks(Iterable<Bookmark> bookmarks) =>
    List<Bookmark>.of(bookmarks)..sort(compareBookmarks);

/// What has to change to turn [current] into [desired].
///
/// [ourOwnJid], when given, is never removed. A bookmark for our own address is
/// our own self-chat, and it is the one entry in the list whose loss cannot be
/// undone by looking at it again: there is no room to re-join and no contact to
/// re-add, only a box to type our own address into. Such a bookmark is reported
/// in [BookmarkPlan.retained] instead of being quietly deleted, because the
/// user did ask for a change and deserves to be told which row did not move.
///
/// The operations come back in a fixed order: the changes to kept bookmarks in
/// the order the user will see them, then the removals. The removals are last
/// because they have no position in the new list, and a plan whose order
/// disagreed with the list on screen is harder to check by eye — which is the
/// only check a reader of a log or a failing test gets to make.
BookmarkPlan diffBookmarks({
  required List<Bookmark> current,
  required List<Bookmark> desired,
  required BookmarkIntent intent,
  String? ourOwnJid,
}) {
  final before = _byKey(current);
  final wanted = _byKey(desired);

  // What the user has, not what somebody asked for. In merge mode that is the
  // existing list plus the asked-for entries, so the union is the whole point;
  // in replace mode it is the asked-for entries alone, which is what leaves
  // anything missing from `desired` free to be removed.
  final kept = <String, Bookmark>{
    if (intent == BookmarkIntent.merge) ...before,
    ...wanted,
  };

  // Where the caller's entry and the stored one are the same bookmark, publish
  // the *stored* one.
  //
  // `matches` deliberately ignores [Bookmark.extensionXml], because a field this
  // module does not model is not a change to make — see its own comment for the
  // ping-pong that treating it as one causes. But that decision only holds if the
  // republish carries the stored record forward. Publishing the caller's copy
  // instead would make every no-op save rewrite the payload we declined to
  // interpret, dropping whatever the other device put there, which then reads
  // back here as a change — the loop the equality rule exists to break, entered
  // from the publishing side instead of the comparing one.
  //
  // Publishing the stored copy is also the honest one on the wire: the server
  // already holds those bytes, so writing them again is a no-op rather than a
  // rewrite of somebody else's data.
  for (final entry in kept.entries.toList()) {
    final existing = before[entry.key];
    if (existing != null && existing.matches(entry.value)) {
      kept[entry.key] = existing;
    }
  }

  final removed = <Bookmark>[];
  final retained = <Bookmark>[];
  final ourKey = ourOwnJid == null ? null : BookmarkUri.parse(ourOwnJid)?.key;
  for (final entry in before.entries) {
    if (kept.containsKey(entry.key)) continue;
    if (entry.key == ourKey) {
      retained.add(entry.value);
      kept[entry.key] = entry.value;
      continue;
    }
    removed.add(entry.value);
  }

  final publishList = orderBookmarks(kept.values);
  final operations = <BookmarkOp>[];
  for (final bookmark in publishList) {
    final existing = before[bookmark.key];
    if (existing == null) {
      operations.add(BookmarkOp(change: BookmarkChange.added, after: bookmark));
    } else if (!existing.matches(bookmark)) {
      operations.add(
        BookmarkOp(
          change: BookmarkChange.updated,
          before: existing,
          after: bookmark,
        ),
      );
    }
  }
  for (final bookmark in orderBookmarks(removed)) {
    operations.add(
      BookmarkOp(change: BookmarkChange.removed, before: bookmark),
    );
  }

  return BookmarkPlan(
    operations: operations,
    publishList: publishList,
    retained: orderBookmarks(retained),
  );
}

/// Indexed by identity, first occurrence winning.
///
/// A duplicate key is a payload we did not write — two items for one room, or a
/// list appended to twice. Which of the two survives is arbitrary; that it is
/// always the *same* one is not. Treating two copies of one bookmark as a
/// difference would make every sync report a change that no amount of
/// publishing could ever clear.
Map<String, Bookmark> _byKey(Iterable<Bookmark> bookmarks) {
  final byKey = <String, Bookmark>{};
  for (final bookmark in bookmarks) {
    byKey.putIfAbsent(bookmark.key, () => bookmark);
  }
  return byKey;
}
