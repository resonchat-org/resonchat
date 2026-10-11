// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Local nicknames: the name *this user* gives somebody, with nothing sent to
// anybody and nothing asked of anybody.
//
// The name on the other side of a chat is not always the name the user thinks
// of that person by, and there is no standard way to fix that — which is
// exactly why this is a local feature, and why its storage has to be defensive.
//
// Three decisions carry the file:
//
//   * **What a nickname may contain.** It is drawn in a one-line row, so a
//     character that draws nothing is not a cosmetic detail. "Bob" and "Bob"
//     with a zero-width space on the end are two different names that look
//     identical on screen, which is a collision the user cannot see and so
//     cannot resolve.
//   * **What the stored form guarantees.** It is an opaque string in a row that
//     a later build owns. A value this build cannot read must cost a nickname,
//     never a conversation.
//   * **Whose name a given string is.** A room's title and a person's name in
//     that room are different questions, and the second one has a
//     catastrophically wrong answer available to the first.
//
// Deliberately imports nothing. This is the only place that decides what a
// nickname may be, so neither storage nor UI gets a vote in it.

/// A name the user chose for a person, guaranteed renderable and trimmed.
///
/// Absent means null, not a value: a `LocalNickname.none` would have to be
/// checked at every use, and could still be stored by accident.
///
/// The constructor is private on purpose. A `LocalNickname` in existence is one
/// that passed [tryParse], so the chat row, the avatar and the mention do not
/// each re-decide what a nickname may contain — and therefore cannot disagree
/// about it.
class LocalNickname {
  const LocalNickname._(this.value);

  /// The name as it is stored and as it is drawn.
  final String value;

  /// The longest a nickname may be, in code points.
  ///
  /// Not UTF-16 units, which is what `String.length` counts: one emoji is two
  /// units and a flag is four, so a 64-unit cap would refuse a name that the
  /// user reads as 32 characters and would be the only nickname rule that
  /// penalises the people who use emoji for their name.
  ///
  /// 64 because that is what fits on one line of a chat row for a full name or
  /// a deliberately silly one, and because past that the input is a paste
  /// rather than a decision.
  static const int maxRunes = 64;

  /// The byte that says which form the rest of the stored column is in.
  ///
  /// A future build that tightens the rules cannot migrate values it has
  /// already made illegal, because an illegal nickname and a nickname that was
  /// never set look the same in a `null`-able column. The version byte is what
  /// makes them tellable apart, and it costs one byte per row.
  static const String storedVersion = '1';

  /// The stored form: [storedVersion] then the name.
  String encode() => '$storedVersion$value';

  /// Reads [encode]d form, or null for anything this build cannot use.
  ///
  /// Never throws and never guesses. A row written by a build that no longer
  /// exists, or one that had a bug, must cost a nickname and not a conversation
  /// — the fallback for an unusable name is the other party's own name, which
  /// is true, and it is a name the user can read and correct.
  ///
  /// A bare string with no version byte is *not* read as text. This column was
  /// introduced together with the byte, so every row that exists was written by
  /// a build that knew the format, and a string without one is a value from
  /// somewhere else. Reading it as a name would also make a name that begins
  /// with a digit ambiguous with a version byte: "404 Gang" is either the name
  /// or version 4 followed by "04 Gang", and neither reading is safe to pick.
  static LocalNickname? decode(String? raw) {
    if (raw == null || raw.length < 2) return null;
    if (raw[0] != storedVersion) return null;
    // Validated again rather than trusted: going through the database is not a
    // way around the rules, and a column value is exactly as hostile as a
    // paste.
    return tryParse(raw.substring(1));
  }

  /// Parses [raw], or null when it cannot be a nickname.
  ///
  /// Null rather than a throw: the text comes out of a row and out of a
  /// clipboard, and neither is a programming error.
  ///
  /// The characters are checked in the string that *arrived*, and the padding
  /// comes off afterwards. That order is the whole of one rule, because
  /// [String.trim] does not only take spaces: it takes every character Unicode
  /// calls whitespace, and U+FEFF, which is the tab and the next-line control
  /// and the byte order mark as well. Trimming first would remove those before
  /// the loop below ever saw them, and hand back a nickname the rules refuse:
  /// "Alex" with a byte order mark in front of it would come out as "Alex",
  /// and "Bob" with a tab after it as "Bob". A name that arrives carrying a
  /// character that draws nothing is refused with that character still in it,
  /// wherever in the name it was.
  ///
  /// The rules, in the order they are applied:
  ///
  /// * **Nothing that draws nothing is allowed, padding included.** A newline in
  ///   a one-line row is a broken layout; a NUL in a row is a truncated string;
  ///   a soft hyphen is drawn by nothing at all. The zero-width family is the
  ///   dangerous half: it survives a copy and a paste, it is invisible in every
  ///   place the user can check, and it makes two names that look the same
  ///   compare as different. Bidi controls are refused for the sharper version
  ///   of the same reason — an override can render "Bob" as something else
  ///   entirely.
  /// * **Trimmed, not refused.** Padding is a habit rather than a mistake, and
  ///   rejecting a name the user can plainly see in the field would leave them
  ///   hunting for the reason. Trimming also makes the stored string, the drawn
  ///   string and the string compared for collisions the same string, which is
  ///   what stops " Bob" and "Bob" from being two entries in one list. Spaces
  ///   are padding; a tab is a character, and the rule above has already had it.
  /// * **A name that is nothing but whitespace is not a name.** It trims to
  ///   nothing, and a nickname field that accepts one produces a chat row with
  ///   a blank title — which reads as a row that failed to load.
  /// * **Capped, refused rather than truncated.** A truncated name is a
  ///   different name that the user never chose, and it can be cut in the
  ///   middle of a word or of a character the display needs a second code unit
  ///   for. There is no way to cut one safely without segmenting grapheme
  ///   clusters, so the input is refused and the caller is left to say why.
  /// * **At least one thing that draws.** The rule above is a blacklist, and a
  ///   blacklist is only as good as the next character somebody invents. So a
  ///   name also has to contain something that renders, which refuses a name
  ///   made entirely of invisible characters even if one of them slips past.
  static LocalNickname? tryParse(String? raw) {
    if (raw == null) return null;
    // Over `raw`, not over what is left of it: see above. Nothing that arrives
    // is quietly removed before it has been judged.
    var somethingVisible = false;
    for (final rune in raw.runes) {
      if (!_renderable(rune)) return null;
      if (_visible(rune)) somethingVisible = true;
    }
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    if (trimmed.runes.length > maxRunes) return null;
    if (!somethingVisible) return null;
    return LocalNickname._(trimmed);
  }

  @override
  bool operator ==(Object other) =>
      other is LocalNickname && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// Drawn when there is nothing at all to name somebody with.
///
/// The same shape as the avatar's "no name" placeholder, and for the same
/// reason: an empty string renders as a row that looks like it failed to load,
/// while a visible mark renders as the answer "we know nothing about this".
const String unknownName = '?';

/// The name to draw for one conversation, one contact or one room.
///
/// The order is local nickname, then the roster title, then the address — the
/// same order in both cases, and that is the point. A local nickname outranks a
/// roster title because a roster title is a name the *other party* chose and can
/// change at any moment, without warning and without ours: a contact who renames
/// themselves silently renames a chat row, and a user who named them locally
/// has said which name they want to use. The address is last because it is the
/// only one of the three that is guaranteed to exist and to be about the right
/// person.
///
/// [localNickname] is re-validated rather than trusted. It arrives as a
/// `String` because it comes out of a row, and the one thing this file must not
/// do is let a value past the rule by arriving through a different door.
///
/// [rosterTitle] is ignored entirely when [isRoom].
///
/// A room is not a contact. Nothing in a roster is titled with a room's JID, so
/// every value this parameter can actually hold for a room is either the
/// address again or somebody's name — and somebody's name is the wrong answer
/// to "what is this conversation called". The room's own name comes through
/// [roomTitle] (bookmark / disco / roomconfig), never through [rosterTitle].
///
/// ```dart
/// /// A room's title never falls back to an occupant.
///
/// /// "Bob" is a correct answer to "who is this person" and a catastrophically
/// /// wrong answer to "what is this conversation called". The two questions
/// /// share this function because the chat list draws both, and a bug here
/// /// renames a room.
/// displayName(
///   localNickname: null,
///   rosterTitle: 'Bob',                      // Bob is *in* this room
///   roomTitle: 'Engineering',
///   jid: 'team@muc.example.org',
///   isRoom: true,
/// ) // 'Engineering'
/// ```
///
/// When [roomTitle] is empty the fallback for a room is the full address rather
/// than the local part, so `team@a.example` and `team@b.example` are two
/// different rows: the slug is often an opaque token, and the domain is the
/// only part of the address that tells two same-named rooms apart.
///
/// The result is never empty. A conversation row with no address at all is not
/// something the app can normally produce, and when it happens the user needs to
/// see *that* rather than a blank title.
String displayName({
  required String? localNickname,
  required String rosterTitle,
  required String jid,
  required bool isRoom,
  String roomTitle = '',
}) {
  final nickname = LocalNickname.tryParse(localNickname);
  if (nickname != null) return nickname.value;
  if (isRoom) {
    final named = roomTitle.trim();
    if (named.isNotEmpty) return named;
    final room = jid.trim();
    return room.isEmpty ? unknownName : room;
  }
  final title = rosterTitle.trim();
  if (title.isNotEmpty) return title;
  final address = jid.trim();
  return address.isEmpty ? unknownName : address;
}

/// What to insert into the composer to address one occupant of a room.
///
/// [text] is the mention. [collidesWith] is the other nicks in the room that
/// this same text also addresses, and it is empty when it is safe.
///
/// The distinction is the whole point of the type: a `String` return would let
/// a caller insert an ambiguous mention without ever learning it was one.
class Mention {
  const Mention({required this.text, this.collidesWith = const []});

  /// What goes into the composer: the room nick behind an `@`.
  ///
  /// Never the local nickname. A local nickname exists on this device and is
  /// not sent to anybody, so a message containing it says nothing to the rest
  /// of the room: they see a name nobody calls them, and their client
  /// highlights nothing. What the user reads on their own screen is chosen by
  /// [displayName]; what goes into a message is chosen here, and the two are
  /// different questions.
  ///
  /// No trailing space: where the caret ends up afterwards is the composer's
  /// business.
  final String text;

  /// Other nicks in the room this text also addresses, in the order the room
  /// listed them and without repeats.
  ///
  /// The number is what a user is told, so "2 people" has to mean two people.
  /// A server that lists one occupant twice is one occupant.
  final List<String> collidesWith;

  /// True when sending [text] would address more than one occupant.
  ///
  /// Reported, never resolved. A room cannot be made unambiguous from here: the
  /// nick is what the server and every other client already use, so a local
  /// rename does not disambiguate anything on the wire. The honest options are
  /// to send a mention that may reach two people or to tell the user it will,
  /// and the app has to be able to say the second.
  bool get ambiguous => collidesWith.isNotEmpty;

  @override
  String toString() =>
      'Mention($text${ambiguous ? ', also $collidesWith' : ''})';
}

/// The mention for the occupant whose room nickname is [nick], or null when
/// there is nothing to address.
///
/// [localNickname] is accepted and deliberately unused; see [Mention.text].
///
/// [occupants] is every nick in the room, including [nick] itself. Taking the
/// whole list rather than the other nicks is deliberate: a caller that
/// remembered to exclude the occupant and a caller that did not would produce
/// different answers for the same room, and the difference would be a collision
/// invented by the call site.
///
/// Returns null for a nick with nothing addressable in it. There is no text we
/// could insert that another client would recognise as addressing them, and
/// inserting something else is a message that appears to be sent to nobody.
Mention? mentionFor({
  required String nick,
  String? localNickname,
  required Iterable<String> occupants,
}) {
  final trimmed = nick.trim();
  if (trimmed.isEmpty) return null;
  for (final rune in trimmed.runes) {
    if (!_renderable(rune)) return null;
  }
  final folded = _folded(trimmed);
  final collisions = <String>[];
  for (final other in occupants) {
    final candidate = other.trim();
    if (candidate.isEmpty || candidate == trimmed) continue;
    if (_folded(candidate) != folded) continue;
    if (collisions.contains(candidate)) continue;
    collisions.add(candidate);
  }
  return Mention(text: '@$trimmed', collidesWith: collisions);
}

/// Case-insensitive comparison, for deciding whether two nicks are one name.
///
/// `toLowerCase` rather than a full case fold: full folding considers "ß" and
/// "ss" the same string, and two occupants with those nicks are two different
/// people to everybody in the room.
String _folded(String value) => value.toLowerCase();

/// The letter an avatar should draw for somebody.
///
/// **The rule: the first character that draws one glyph, preferring a letter —
/// and a letter is whatever Unicode calls general category `L`, asked for with
/// `\p{L}`, not a range table kept in this file.** A table could not answer that
/// question: the one it replaced named BMP code points only, so `𠮷` (U+20BB7,
/// a CJK ideograph in extension B) came out as a non-letter and the scan walked
/// past a real name character to the one after it, and a table is also a
/// hand-copied duplicate of a fact the SDK already holds, so it is wrong again
/// the next time somebody adds a block. `\p{L}` *is* the fact, on every plane,
/// which is why there is no list here to go stale — if you are about to add one,
/// the question to ask is not which ranges but whether the category answers it.
///
/// The cost is one pattern compiled at load and one match against a one- or
/// two-unit string per candidate, with the scan stopping at the first letter:
/// this runs once per avatar circle, not once per frame, so asking the SDK is
/// not a performance question. What `\p{L}` does *not* answer is whether a
/// character draws anything, which is a different question and is answered
/// below.
///
/// A superset of `avatarInitial` in `../xmpp/avatar.dart`, defined here rather
/// than imported: that one takes the first code point of the name whatever it
/// is, and every case below is a case where that produces something that is not
/// a glyph. The cases handled here and not there:
///
/// * **A name with nothing visible in it is a question mark.** Nothing else in
///   this app validates a display name, so a row whose nickname is a single
///   zero-width space is an ordinary row that loads without complaint — and
///   taking its first code point draws that character, which draws nothing, in a
///   circle that therefore looks like a spinner.
/// * **Invisible characters are skipped before the fallback too, not only
///   before the first letter.** A name of "a zero-width space and an emoji"
///   has no letter in it, so the fallback is what runs, and skipping nothing
///   there returns the invisible character instead of the emoji.
/// * **Grapheme sequences come back whole.** A ZWJ sequence, a skin-tone
///   modifier and a flag are several code points that are one picture, and the
///   first code point alone is a different picture: the man of a family, or a
///   letter in a box. This is true of a sequence that *starts* with a letter
///   too: a Devanagari conjunct is two letters and a joiner, and the first rune
///   on its own is not a thing anybody writes.
/// * **Digits and symbols are not letters, in every script on every plane.**
///   They are other general categories — `N` and `S` — so the single category
///   test above excludes "4", "५", "๕", "𝟜", "×" and "÷" together. Ranges could
///   not: those digits sit *inside* the Devanagari and Thai blocks and `×` and
///   `÷` sit *inside* Latin-1, so each one needed a hole cut for it by hand and
///   the next script needed another hand.
/// * **Anything that draws is still the fallback.** A name of only digits, or
///   only emoji, has no letter in it, and the first thing that draws is a
///   better avatar than a question mark.
String firstInitial(String name, String jid) {
  final trimmedName = name.trim();
  final trimmedJid = jid.trim();
  final source = trimmedName.isNotEmpty ? trimmedName : trimmedJid;
  if (source.isEmpty) return unknownName;
  final runes = source.runes.toList();

  // Two passes, because "no letter" is not "nothing to draw". A name of only
  // digits or only emoji still has a glyph, and the first one that renders is a
  // better avatar than a question mark.
  var start = _indexOf(runes, _isLetter);
  if (start < 0) start = _indexOf(runes, _visible);
  if (start < 0) return unknownName;

  return String.fromCharCodes(runes.sublist(start, _endOfGlyph(runes, start)))
      .toUpperCase();
}

/// Where the picture that starts at [start] ends.
///
/// One emoji is several code points and they have to be taken together: the man
/// at the start of a family is not a smaller version of the family, and half of
/// a flag is a letter in a box.
int _endOfGlyph(List<int> runes, int start) {
  var end = start + 1;
  var joined = false;
  for (var i = start + 1; i < runes.length; i++) {
    final rune = runes[i];
    if (rune == 0x200D) {
      joined = true;
      continue;
    }
    if (joined || _joins(rune)) {
      joined = false;
      // The index is *not* advanced past this rune as well: the joiner before
      // it is what pulled it in, and a sequence of three or more code points —
      // a family, a conjunct — puts another joiner at i + 1. Stepping over that
      // joiner ends the sequence at its second element, which is the man of the
      // family rather than the family.
      end = i + 1;
      continue;
    }
    break;
  }
  // A flag is two regional indicators and the pair is the flag; either one alone
  // is drawn as an empty box.
  if (_isRegionalIndicator(runes[start]) &&
      end < runes.length &&
      _isRegionalIndicator(runes[end])) {
    return end + 1;
  }
  return end;
}

bool _isRegionalIndicator(int rune) => rune >= 0x1F1E6 && rune <= 0x1F1FF;

int _indexOf(List<int> runes, bool Function(int) test) {
  for (var i = 0; i < runes.length; i++) {
    if (test(runes[i])) return i;
  }
  return -1;
}

/// Characters that draw nothing at all on their own.
///
/// Control characters, the zero-width and bidi families, the private-use areas
/// and the lone surrogates a bad decode leaves behind. A name containing one of
/// these is either invisible, a spoofing vector, or a string that survives a
/// database write differently than it survived a paste.
bool _drawsNothing(int rune) =>
    _joins(rune) ||
    (rune >= 0x00 && rune <= 0x1F) ||
    rune == 0x7F ||
    (rune >= 0x80 && rune <= 0x9F) ||
    (rune >= 0x200B && rune <= 0x200F) ||
    (rune >= 0x202A && rune <= 0x202E) ||
    (rune >= 0x2060 && rune <= 0x2069) ||
    rune == 0x00AD ||
    rune == 0xFEFF ||
    (rune >= 0xD800 && rune <= 0xDFFF) ||
    (rune >= 0xE000 && rune <= 0xF8FF) ||
    (rune >= 0xFFF9 && rune <= 0xFFFB) ||
    (rune >= 0xF0000 && rune <= 0xFFFFD) ||
    (rune >= 0x100000 && rune <= 0x10FFFD);

/// Characters that join to the picture before them, and so are invisible alone.
///
/// Allowed in a nickname even though they draw nothing, because refusing them
/// refuses the emoji they spell: a family, a hand with a skin tone, a flag. The
/// trade is a nickname made *only* of joiners, and that is caught by the rule
/// that a name has to contain something that draws.
bool _joins(int rune) =>
    rune == 0x200D ||
    (rune >= 0xFE00 && rune <= 0xFE0F) ||
    (rune >= 0x1F3FB && rune <= 0x1F3FF) ||
    (rune >= 0xE0020 && rune <= 0xE007F);

/// Whether a nickname may contain [rune].
bool _renderable(int rune) => !_drawsNothing(rune) || _joins(rune);

/// Whether [rune] puts something on screen.
bool _visible(int rune) => !_drawsNothing(rune) && !_isSpace(rune);

bool _isSpace(int rune) =>
    rune == 0x20 ||
    (rune >= 0x09 && rune <= 0x0D) ||
    rune == 0x85 ||
    rune == 0xA0 ||
    rune == 0x1680 ||
    (rune >= 0x2000 && rune <= 0x200A) ||
    rune == 0x2028 ||
    rune == 0x2029 ||
    rune == 0x202F ||
    rune == 0x205F ||
    rune == 0x3000;

/// Matches one character of Unicode general category `L`: a letter.
///
/// The answer to "is this a letter", asked rather than tabulated. `L` covers
/// Lu, Ll, Lt and Lm across every script and every plane, so there is no block
/// to add and nothing to forget: a digit is `N`, a symbol is `S`, a mark is `M`,
/// and none of them is a letter in any of them.
///
/// `unicode: true` is what makes `\p{L}` a legal pattern at all, and what makes
/// the engine match a surrogate pair as the one code point it is — without it a
/// character above the BMP is two units to the pattern and matches nothing.
///
/// Compiled once because the question is asked once per leading character of
/// one name, in a function that draws an avatar circle: not a hot path, and not
/// a reason to cache anything cleverer.
final RegExp _letterPattern = RegExp(r'\p{L}', unicode: true);

/// Whether [rune] is a letter, of any script, on any plane.
bool _isLetter(int rune) => _letterPattern.hasMatch(String.fromCharCode(rune));
