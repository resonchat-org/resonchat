// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Contact cards — XEP-0054, vCard-temp / RFC 2426.
//
// The card a contact publishes about themselves, and the only place a name
// that is not a JID comes from. This file is the value and decision layer for
// it: parsing, field extraction, and the rule for what to call somebody. No
// network, no storage, no widgets — the layers above decide when to fetch and
// where to draw it.
//
// Everything here operates on text written by a client we do not control, and
// most of that text ends up rendered next to a person's messages. Three
// decisions carry the file, and all three are about what to *believe* rather
// than how to parse:
//
//   * Strict about what we accept, lenient about what we reject. One
//     unreadable field must never cost us the name sitting beside it, and a
//     malformed card must never take the profile page down with it.
//   * A missing field means "the publisher did not tell us", and nothing in
//     this file may conclude anything stronger than that from it.
//   * Nothing reaches a widget without passing a sanitiser, because a
//     zero-width joiner in somebody's name is an ordinary accident and an RTL
//     override in it is not.

import 'dart:convert';
import 'dart:typed_data';

import 'package:xml/xml.dart';

/// The vCard-temp namespace.
///
/// Spelled out here rather than imported from moxxmpp (which exports the same
/// value as `vCardTempXmlns`): this module is the value layer and a namespace
/// string is not a reason for it to depend on the connection layer or, through
/// that, on the database. Two constants that cannot disagree because neither of
/// them computes anything.
const String vCardTempNamespace = 'vcard-temp';

/// Longest single-line field kept: names, titles, phone numbers.
///
/// 120 characters is far past what a chat row can show before it ellipsises,
/// and it bounds what a hostile card can put into one list row. The cap is
/// measured in code points, not UTF-16 units, so it can never land in the
/// middle of a character — including an emoji, which is two units wide.
const int maxVCardNameLength = 120;

/// Longest free-text field kept (NOTE, and the address components).
///
/// 400 is roughly a paragraph. A note is a paragraph or two; it is not a
/// document, and how tall the profile page becomes is not something a stranger
/// gets to decide.
const int maxVCardTextLength = 400;

/// Largest inline photo decoded out of a card, before decoding.
///
/// XEP-0084 exists precisely because a vCard photo is too big to move reliably
/// inside an IQ, so a card carrying one this size is a client doing it the hard
/// way rather than a portrait. The check happens *before* `base64Decode`:
/// decoding a 50 MB string because a stranger put it in a business card is a
/// memory spike this app has no reason to absorb.
const int maxVCardPhotoBytes = 192 * 1024;

/// Base64 length that could decode to more than [maxVCardPhotoBytes].
const int maxVCardPhotoBase64 = maxVCardPhotoBytes * 4 ~/ 3 + 4;

/// One PHOTO, and only when it is something we can actually put on screen.
class VCardPhoto {
  const VCardPhoto({required this.bytes, required this.mimeType});

  final Uint8List bytes;

  /// Guessed from [bytes], never taken from the `<TYPE>` the publisher sent.
  ///
  /// The declared type is chosen by whoever published the photo, and the only
  /// bytes that get decoded are [bytes]. Trusting the label means letting a
  /// peer hand this client a blob claiming to be something the image decoder
  /// was not written for.
  final String mimeType;
}

/// The components of an `N`, as separate strings rather than one pre-joined
/// name.
///
/// Kept unjoined because a card that carries both `N` and `FN` will render them
/// in two different places, and the caller has to be able to say which is the
/// chosen display name and which is the structured fact behind it.
class StructuredName {
  const StructuredName({
    this.prefix,
    this.given,
    this.additional,
    this.family,
    this.suffix,
  });

  final String? prefix;
  final String? given;
  final String? additional;
  final String? family;
  final String? suffix;

  /// True when no component survived parsing.
  bool get isEmpty =>
      prefix == null &&
      given == null &&
      additional == null &&
      family == null &&
      suffix == null;

  /// This name rendered the way `FN` renders it, or null when there is nothing
  /// to render.
  ///
  /// Given name first, then the family name — the vCard-temp convention, and
  /// the one the overwhelming majority of publishers put in `FN` themselves.
  /// Where a person's culture puts the family name first this is the wrong
  /// order, and it is wrong in exactly the same way as their own `FN` would
  /// have been: nothing in the card says which order the person uses, and the
  /// publisher's answer is the only evidence available. Preferring `FN` over
  /// this (see [preferredDisplayName]) is what stops one contact appearing
  /// under two different names in two different screens.
  String? get formatted {
    final parts = <String>[?prefix, ?given, ?additional, ?family, ?suffix];
    return parts.isEmpty ? null : parts.join(' ');
  }
}

/// One ADR, unflattened.
class PostalAddress {
  const PostalAddress({
    this.poBox,
    this.extended,
    this.street,
    this.locality,
    this.region,
    this.postalCode,
    this.country,
  });

  final String? poBox;
  final String? extended;
  final String? street;
  final String? locality;
  final String? region;
  final String? postalCode;
  final String? country;

  /// True when no component survived parsing.
  bool get isEmpty =>
      poBox == null &&
      extended == null &&
      street == null &&
      locality == null &&
      region == null &&
      postalCode == null &&
      country == null;

  /// The address on one line, in RFC 2426 §3.3.1 component order.
  ///
  /// One line because every place this is shown — the profile page, a contact
  /// sheet — has one line for it, and vCard's seven components exist to be
  /// formatted, not to be stacked. Which order to stack them in is the
  /// publisher's choice; the spec order is the only one both ends agree on.
  String? get oneLine {
    final parts = <String>[
      ?poBox,
      ?extended,
      ?street,
      ?locality,
      ?region,
      ?postalCode,
      ?country,
    ];
    return parts.isEmpty ? null : parts.join(', ');
  }
}

/// One contact's published card.
///
/// Every field is optional because every field is optional in practice: the
/// most common card in the world is an `FN` and nothing else, and a client that
/// required more would show a JID for most of its contacts.
///
/// A null field means **the card gave us nothing usable** — which deliberately
/// collapses two different things: the element was never sent, and the element
/// was sent and sanitised down to nothing (an empty string, or one that was
/// only zero-width joiners and control characters). They are collapsed because
/// there is no screen in this app that shows "no email address" differently
/// from "an email address that contained nothing drawable", and carrying both
/// would put a null check in every caller for a distinction none of them can
/// act on. What a null field must *not* be read as is "this contact has none":
/// the truthful reading is "we do not know", and the fields are kept separate
/// for exactly that reason.
class VCard {
  const VCard({
    this.formattedName,
    this.structuredName,
    this.nickname,
    this.organisation,
    this.jobTitle,
    this.role,
    this.url,
    this.address,
    this.phone,
    this.email,
    this.birthday,
    this.note,
    this.photo,
  });

  /// `FN` — the name the publisher formatted for display.
  final String? formattedName;

  /// `N` — the same person's name in components.
  final StructuredName? structuredName;

  /// `NICKNAME`.
  final String? nickname;

  /// `ORG`, first entry. See [preferredDisplayName] for why this is never used
  /// as somebody's name.
  final String? organisation;

  /// `TITLE` — the job title.
  final String? jobTitle;

  /// `ROLE` — what they do, in prose. Distinct from [jobTitle]: "Engineer" is a
  /// title, "the only one who knows the build system" is a role.
  final String? role;

  /// `URL`, first entry.
  final String? url;

  /// `ADR`, first entry.
  final PostalAddress? address;

  /// `TEL`, first entry.
  final String? phone;

  /// `EMAIL`, first entry. Not validated as an address: it is free text that a
  /// client published about itself, and a card that lies about it costs us a
  /// tap on a wrong link rather than a crash.
  final String? email;

  /// `BDAY`, verbatim.
  ///
  /// Kept as text rather than parsed to a date. RFC 2426 allows a bare year,
  /// a full timestamp, and free-form "circa 1970", and the birthday is not
  /// worth a field that is either null or wrong for a quarter of real cards.
  /// Anything that needs it as a date can parse it where the ambiguity is
  /// visible.
  final String? birthday;

  /// `NOTE` — free text, newlines preserved.
  final String? note;

  /// `PHOTO`, inline only. See [VCardPhoto].
  final VCardPhoto? photo;
}

/// What to call this contact in the UI.
///
/// The order is **NICKNAME, then `FN`, then a reconstruction of `N`, then the
/// JID**. Three decisions in there, each of which looks arbitrary:
///
/// NICKNAME beats FN. A person who set a nickname on a client did so because
/// they wanted to be called that; FN is whatever their account was created
/// with, which they may not have looked at since. Getting this backwards is how
/// a contact list ends up showing "bobsmith1987" next to "Robert", and it is
/// the complaint that produces the feature request "let me choose my name".
///
/// FN beats a reconstructed `N`, even though the reconstruction is built to
/// look exactly like an FN would. FN is the publisher's own resolution of
/// exactly the question we cannot answer — in which order this person writes
/// their name. Preferring our reconstruction means a contact with both can be
/// rendered two ways in the same app: the chat list uses `FN` somewhere else
/// and the profile uses `Wei Chen` from `N`, and the user is looking at one
/// person.
///
/// ORG is never the answer, and this is the decision most likely to be got
/// wrong by putting it in as a last resort before the JID. An organisation in
/// the title slot of a 1:1 conversation reads as "this chat is with a company",
/// which is false, and on a domain with a shared address the same string appears
/// on every contact — so the one field that could have disambiguated them is
/// the field that makes them indistinguishable. [VCard.organisation] is exposed
/// for the profile page, where "works at" is a true and useful thing to say.
///
/// The JID is the floor because it is the only value in the whole card that the
/// contact cannot get wrong: it is the address the messages actually arrive
/// from, and a name that is wrong is worse than an address that is ugly.
///
/// This knows nothing about the roster's own `name` for the contact. Which of
/// those two outranks which is a question about who typed the name — the person
/// who added the contact, or the contact — and it belongs to whoever has both,
/// not here.
///
/// The result is sanitised on the way out as well as on the way in. The two are
/// idempotent, so doing it in both places means neither this function nor the
/// UI above it has to know whether the [VCard] came from [parseVCard] or was
/// built by hand.
String preferredDisplayName(VCard vcard, String fallbackJid) {
  final candidates = <String?>[
    vcard.nickname,
    vcard.formattedName,
    vcard.structuredName?.formatted,
  ];
  for (final candidate in candidates) {
    final clean = sanitiseVCardLine(candidate);
    if (clean != null) return clean;
  }
  // The JID is sanitised too. It arrives from a roster push or a presence, and
  // a name column is not a place where an unsanitised string is acceptable just
  // because it came from a protocol field we trust for routing.
  return sanitiseVCardLine(fallbackJid) ?? '';
}

/// The single glyph to draw in an avatar circle for [name].
///
/// [fallbackJid] is consulted when [name] holds nothing drawable, and `'?'` is
/// returned when neither does — a question mark is a thing that renders, where
/// "no initial" would be an empty circle indistinguishable from a broken image.
///
/// This is a deliberate superset of `avatarInitial` in `avatar.dart`, which
/// stays as it is because that module is owned by the connection layer and this
/// one has to stand alone. The cases it handles that theirs does not:
///
///   * A name with no letter anywhere. That version falls back to
///     `source.runes.first`, which is an emoji for a nickname like "🔥", a
///     lone combining mark for a name that begins with a stray diacritic, or a
///     bidi control — none of which is a letter, and an emoji at circle-font
///     size overflows the circle. Here the passes are: first letter, then first
///     digit, then the JID, then '?'.
///   * A case mapping that changes length. `toUpperCase` turns "ß" into "SS",
///     so a two-glyph initial in a 32-pixel circle reads as a typo; a mapping
///     that does not leave exactly one rune is declined.
///   * Scripts that version covers not at all: Devanagari and the other Indic
///     blocks, Thai, Georgian, Ethiopic, Cherokee, Khmer, CJK extension A, and
///     the Latin Extended Additional that Vietnamese names live in.
///   * A leading combining mark, in any of the cases above.
String vcardInitial(String name, String fallbackJid) {
  return _firstDrawableRune(name) ?? _firstDrawableRune(fallbackJid) ?? '?';
}

/// The first letter in [source], or failing that its first digit.
String? _firstDrawableRune(String source) {
  int? digit;
  for (final rune in source.runes) {
    // A mark with nothing in front of it is not a letter and does not draw on
    // its own; this is how a name whose first character is an Arabic or
    // Devanagari diacritic ends up blank.
    if (_isCombiningMark(rune)) continue;
    if (_isLetterRune(rune)) return _capitalise(rune);
    if (digit == null && _isDigitRune(rune)) digit = rune;
  }
  return digit == null ? null : _capitalise(digit);
}

String _capitalise(int rune) {
  final raw = String.fromCharCode(rune);
  final upper = raw.toUpperCase();
  return upper.runes.length == 1 ? upper : raw;
}

/// Cleans a value that will be drawn on one line.
///
/// Returns null when nothing usable is left, so "the card said nothing" and
/// "the card said something we refuse to draw" are the same answer to every
/// caller and neither of them has to grow a second branch.
String? sanitiseVCardLine(String? raw, {int maxLength = maxVCardNameLength}) =>
    _sanitise(raw, maxLength: maxLength, keepNewlines: false);

/// Cleans free text that is allowed to be more than one line (`NOTE`).
///
/// Same rules as [sanitiseVCardLine], with two differences: line breaks are
/// kept, because a note that arrives as one line is a note nobody can read, and
/// the cap is looser, because the note is not the string that ends up in a list
/// row.
String? sanitiseVCardText(String? raw, {int maxLength = maxVCardTextLength}) =>
    _sanitise(raw, maxLength: maxLength, keepNewlines: true);

/// Removes what must never be drawn, collapses whitespace and caps the length.
///
/// Applied at parse time, so a [VCard] that came from [parseVCard] is safe to
/// interpolate anywhere without the caller re-checking it. Doing it here rather
/// than in the widgets is the point: four screens draw these strings and each
/// one would otherwise implement a slightly different subset, and the subset
/// that gets forgotten is the one that ships.
String? _sanitise(
  String? raw, {
  required int maxLength,
  required bool keepNewlines,
}) {
  if (raw == null) return null;
  final kept = <int>[];
  var pendingSpace = false;
  for (final rune in raw.runes) {
    // Whitespace is normalised *before* anything is dropped. The order is
    // load-bearing: the control-character range includes CR and LF, so testing
    // "never drawn" first deleted a newline out of `Alex\nChen` and produced
    // `AlexChen` — two words run together in a contact list, which is worse than
    // either the newline or the space being wrong.
    if (_isSpaceOrBreak(rune)) {
      // CR, LF and NEL are all "a line ended here" to a renderer, and CRLF is
      // two of them — so they are one code point from here on, never a stray
      // carriage return in the middle of a name.
      final isBreak =
          keepNewlines && (rune == 0x0A || rune == 0x0D || rune == 0x85);
      if (!isBreak) {
        // Held back rather than emitted: a run of spaces becomes one, and a
        // trailing one is never written at all.
        pendingSpace = true;
        continue;
      }
      pendingSpace = false;
      // At most one blank line. How tall the profile page becomes is a
      // rendering decision, not something the publisher of a business card
      // gets to make.
      if (kept.length < 2 ||
          kept[kept.length - 1] != 0x0A ||
          kept[kept.length - 2] != 0x0A) {
        kept.add(0x0A);
      }
      continue;
    }
    if (_isNeverDrawn(rune)) continue;
    if (pendingSpace && kept.isNotEmpty) kept.add(0x20);
    pendingSpace = false;
    kept.add(rune);
  }

  var start = 0;
  while (start < kept.length && _isCollapsedWhitespace(kept[start])) {
    start++;
  }
  var end = kept.length;
  while (end > start && _isCollapsedWhitespace(kept[end - 1])) {
    end--;
  }
  if (start >= end) return null;

  if (end - start > maxLength) {
    end = start + maxLength;
    while (end > start && _isCollapsedWhitespace(kept[end - 1])) {
      end--;
    }
  }

  // A trailing combining mark is dropped whether or not anything was truncated.
  //
  // This used to live inside the truncation branch, which meant a name that was
  // *exactly* at the cap kept a mark with nothing to attach to — the identical
  // stray glyph the truncation case was written to prevent, reachable by making
  // the input one character shorter. Whether a name ends in a dangling accent has
  // nothing to do with how long it is, so the cleanup does not belong under a
  // length test.
  while (end > start && _isCombiningMark(kept[end - 1])) {
    end--;
  }

  return String.fromCharCodes(kept.sublist(start, end));
}

/// Characters that are dropped whatever else is true of them.
///
/// The bidi controls are the sharp end of this list and the reason it exists:
/// U+202E makes everything after it render in reverse, so a contact whose name
/// is `gnp\u202Etxt.exe` is shown as `exe.txt`. A name that displays as something
/// other than what it says is the one field in a messenger that cannot be
/// treated as decoration.
///
/// Variation selectors (U+FE00–U+FE0F) are deliberately *not* on this list.
/// They change how a glyph is drawn rather than hiding it, and removing one
/// would visibly alter a character somebody chose.
bool _isNeverDrawn(int r) {
  if (r < 0x20 || r == 0x7F) return true; // C0 controls and DEL
  if (r >= 0x80 && r <= 0x9F) return true; // C1 controls, including NEL
  if (r >= 0xD800 && r <= 0xDFFF) return true; // unpaired surrogate
  if (r == 0x00AD || r == 0x061C || r == 0x180E) {
    return true; // soft hyphen, ALM
  }
  if (r >= 0x200B && r <= 0x200F) return true; // ZWSP, ZWNJ, ZWJ, LRM, RLM
  if (r >= 0x202A && r <= 0x202E) return true; // bidi embedding and override
  if (r >= 0x2060 && r <= 0x2064) return true; // word joiner, invisible maths
  if (r >= 0x2066 && r <= 0x2069) return true; // bidi isolates
  if (r >= 0xFFF9 && r <= 0xFFFB) return true; // interlinear annotation
  if (r == 0xFEFF) return true; // BOM, used everywhere as ZWNBSP
  if (r >= 0xE0000 && r <= 0xE007F) return true; // Unicode tag characters
  if (r >= 0xE0100 && r <= 0xE01EF) return true; // variation selectors supp.
  return false;
}

bool _isSpaceOrBreak(int r) =>
    r == 0x20 ||
    r == 0x09 ||
    (r >= 0x0A && r <= 0x0D) ||
    r == 0x85 ||
    r == 0xA0 || // no-break space, which reads as a wide gap in a name
    r == 0x1680 ||
    (r >= 0x2000 && r <= 0x200A) ||
    r == 0x2028 ||
    r == 0x2029 ||
    r == 0x202F ||
    r == 0x205F ||
    r == 0x3000; // ideographic space

/// Only 0x20 and 0x0A survive [_sanitise], so trimming is exactly these two.
bool _isCollapsedWhitespace(int r) => r == 0x20 || r == 0x0A;

/// True for a combining mark, which is never the initial and never survives a
/// truncation on its own.
///
/// Ranges rather than a Unicode property table because the only thing this
/// decides is "could this mark start a name", and the answer that matters in
/// practice is the Arabic, Hebrew, Devanagari, Thai and generic diacritic
/// blocks — a mark that follows a base character is left alone.
bool _isCombiningMark(int r) =>
    (r >= 0x0300 && r <= 0x036F) ||
    (r >= 0x0483 && r <= 0x0489) ||
    (r >= 0x0591 && r <= 0x05BD) ||
    (r >= 0x05BF && r <= 0x05C7) ||
    (r >= 0x0610 && r <= 0x061A) ||
    (r >= 0x064B && r <= 0x065F) ||
    r == 0x0670 ||
    (r >= 0x06D6 && r <= 0x06ED) ||
    (r >= 0x0900 && r <= 0x0903) ||
    (r >= 0x093A && r <= 0x094F) ||
    (r >= 0x0951 && r <= 0x0957) ||
    r == 0x0E31 ||
    (r >= 0x0E34 && r <= 0x0E3A) ||
    (r >= 0x0E47 && r <= 0x0E4E) ||
    (r >= 0x1AB0 && r <= 0x1AFF) ||
    (r >= 0x1DC0 && r <= 0x1DFF) ||
    (r >= 0x20D0 && r <= 0x20FF) ||
    (r >= 0xFE20 && r <= 0xFE2F);

/// Blocks in which a rune is a letter, covering the scripts a contact in this
/// app can plausibly be named in.
const List<(int, int)> _letterRanges = <(int, int)>[
  (0x0041, 0x005A), // Latin
  (0x0061, 0x007A),
  (0x00C0, 0x024F), // Latin-1 supplement, Latin Extended A and B
  (0x0370, 0x05FF), // Greek, Cyrillic, Armenian
  (0x0600, 0x06FF), // Hebrew, Arabic
  (0x0700, 0x074F), // Syriac
  (0x0780, 0x07BF), // Thaana
  (0x07C0, 0x07FF), // NKo, Samaritan, Mandaic
  (0x0900, 0x097F), // Devanagari, Bengali
  (0x0980, 0x0DFF), // the rest of the Indic scripts
  (0x0E00, 0x0E7F), // Thai, Lao
  (0x1000, 0x109F), // Myanmar
  (0x10A0, 0x10FF), // Georgian
  (0x1200, 0x139F), // Ethiopic
  (0x13A0, 0x13FF), // Cherokee
  (0x1400, 0x167F), // Canadian aboriginal syllabics
  (0x1680, 0x169F), // Ogham
  (0x16A0, 0x16FF), // Runic
  (0x1780, 0x17FF), // Khmer, Mongolian
  (0x1E00, 0x1EFF), // Latin Extended Additional — Vietnamese names
  (0x1F00, 0x1FFF), // Greek Extended
  (0x2C60, 0x2C7F), // Latin Extended-C
  (0x2D00, 0x2D2F), // Georgian supplement
  (0x3040, 0x30FF), // Hiragana, Katakana
  (0x3100, 0x312F), // Bopomofo
  (0x3400, 0x4DBF), // CJK unified ideographs extension A
  (0x4E00, 0x9FFF), // CJK unified ideographs
  (0xA720, 0xA7FF), // Latin Extended-D
  (0xAC00, 0xD7AF), // Hangul syllables
  (0xF900, 0xFAFF), // CJK compatibility ideographs
  (0xFF21, 0xFF3A), // Fullwidth Latin
  (0xFF41, 0xFF5A),
  (0xFF66, 0xFF9F), // Halfwidth katakana
];

bool _isLetterRune(int r) {
  for (final range in _letterRanges) {
    if (r >= range.$1 && r <= range.$2) return true;
  }
  return false;
}

const List<(int, int)> _digitRanges = <(int, int)>[
  (0x0030, 0x0039),
  (0x0660, 0x0669), // Arabic-Indic
  (0x06F0, 0x06F9), // extended Arabic-Indic
  (0xFF10, 0xFF19), // fullwidth
];

bool _isDigitRune(int r) {
  for (final range in _digitRanges) {
    if (r >= range.$1 && r <= range.$2) return true;
  }
  return false;
}

/// Parses a `<vCard/>` out of [element], or null when there is none in it.
///
/// [element] may be the card itself or anything wrapping it — a whole
/// `<iq type="result"/>`, a `<vCardUpdate/>` payload — because the caller
/// usually has the response in hand and the card is two levels down, and
/// picking it out here is the only reason this function has to know about
/// element names at all.
///
/// ## Strict about what it accepts, lenient about what it rejects
///
/// Strict on values: unknown elements are ignored rather than treated as
/// fields, a `BINVAL` that is not base64 is dropped rather than stored, and a
/// photo that is not an image is dropped rather than decoded. Strictness here
/// is free, because a wrong value costs one field.
///
/// Lenient everywhere a strict reading would cost the whole card: a property
/// name in the wrong case, an `N` with three components instead of five, a
/// duplicate `FN`, markup inside a value, a `vCard` in the wrong namespace, an
/// element from a namespace we have never heard of, a card with nothing in it
/// at all. None of those throw, and none of them discard the `FN` sitting next
/// to them. This data comes from a client we do not control and it ends up
/// rendered in our UI, so the cost of a throw is somebody's profile page
/// failing to open over a stray capital letter, and the cost of leniency is at
/// worst one slightly odd string in one list row.
///
/// The one place leniency stops is a property's *parameters*. `<TYPE>`,
/// `<PREF>` and `<ENCODING>` are children of the property that carries them,
/// so reading a value as "all the text underneath" would concatenate them into
/// the value: a card with `<TEL><TYPE>pref</TYPE>+441234</TEL>` would put the
/// phone number through as "pref+441234". [\_ownText] is why that does not
/// happen.
VCard? parseVCard(XmlElement element) {
  final card = _findCard(element);
  if (card == null) return null;
  return VCard(
    formattedName: _preferredText(card, 'FN'),
    structuredName: _structuredName(_firstNamed(card, 'N')),
    nickname: _preferredText(card, 'NICKNAME'),
    organisation: _preferredText(card, 'ORG'),
    jobTitle: _preferredText(card, 'TITLE'),
    role: _preferredText(card, 'ROLE'),
    url: _preferredText(card, 'URL'),
    address: _address(_firstNamed(card, 'ADR')),
    phone: _preferredText(card, 'TEL'),
    email: _preferredText(card, 'EMAIL'),
    birthday: _preferredText(card, 'BDAY'),
    // `maxVCardTextLength`, not the name default: a note is prose and a name is a
    // label, and the module defines a wider cap for exactly this field. Passing
    // nothing here silently truncated every note to the name length — a constant
    // that existed, was exported, was tested against, and reached no caller.
    note: _preferredText(
      card,
      'NOTE',
      maxLength: maxVCardTextLength,
      keepNewlines: true,
    ),
    photo: _photo(_preferredElement(card, 'PHOTO')),
  );
}

/// Parses a vCard out of a raw XML string, or null when there is none.
///
/// Null for malformed XML as well, on the same reasoning as [parseVCard]: XML
/// that does not parse did not come from a card, and "no card" is the answer
/// the UI already knows how to draw.
VCard? parseVCardResponse(String xml) {
  try {
    return parseVCard(XmlDocument.parse(xml).rootElement);
  } catch (_) {
    return null;
  }
}

XmlElement? _findCard(XmlElement element) {
  // Case-insensitive: RFC 2426 §2.1 makes property names case-insensitive,
  // `vCard` is what the spec says, and a fair number of servers and gateways
  // send `vcard`. Not checking the namespace at all is the same leniency one
  // step further — a server that rewrites the declaration is more common than
  // one that sends something else under the same name.
  if (element.name.local.toUpperCase() == 'VCARD') return element;
  for (final descendant in element.findAllElements('*', namespace: '*')) {
    if (descendant.name.local.toUpperCase() == 'VCARD') return descendant;
  }
  return null;
}

Iterable<XmlElement> _childrenNamed(XmlElement parent, String wanted) =>
    parent.childElements.where((e) => e.name.local.toUpperCase() == wanted);

XmlElement? _firstNamed(XmlElement parent, String wanted) {
  for (final el in _childrenNamed(parent, wanted)) {
    return el;
  }
  return null;
}

/// The text of [el] itself, ignoring its child elements.
///
/// Not `innerText`, which concatenates the whole subtree — see the note on
/// [parseVCard] for what that would fold into a phone number.
String _ownText(XmlElement el) {
  final buffer = StringBuffer();
  for (final node in el.children) {
    if (node is XmlText) {
      buffer.write(node.value);
    } else if (node is XmlCDATA) {
      buffer.write(node.value);
    }
  }
  return buffer.toString();
}

/// The element the publisher marked as the one to use, or the first.
///
/// `NICKNAME`, `ORG`, `URL`, `TEL`, `EMAIL`, `ADR` and `PHOTO` are all
/// repeatable, and RFC 2426 §2.5.1 says the one carrying `PREF` is the one to
/// use. Taking the first blindly means the phone number we show is whichever
/// one the client happened to serialise first — which on a phone that syncs
/// several numbers is very often not the one the person answers.
XmlElement? _preferredElement(XmlElement parent, String wanted) {
  for (final el in _childrenNamed(parent, wanted)) {
    if (_markedPreferred(el)) return el;
  }
  return _firstNamed(parent, wanted);
}

bool _markedPreferred(XmlElement el) {
  for (final child in el.childElements) {
    final tag = child.name.local.toUpperCase();
    if (tag == 'PREF') return true;
    // vCard 2.1 marked preference on the TYPE value rather than a child
    // element, and clients still emit it that way.
    if (tag == 'TYPE' && _ownText(child).trim().toLowerCase() == 'pref') {
      return true;
    }
  }
  return false;
}

/// The best usable value among the repeatable [wanted] properties of [parent].
///
/// "Best" is the `PREF`-marked one if any of them has one, otherwise the first
/// that yields anything at all. Skipping the empty candidates is what makes
/// `<NICKNAME></NICKNAME><NICKNAME>bob</NICKNAME>` read as "bob" instead of
/// as a contact with no nickname.
String? _preferredText(
  XmlElement parent,
  String wanted, {
  int maxLength = maxVCardNameLength,
  bool keepNewlines = false,
}) {
  final matches = _childrenNamed(parent, wanted).toList();
  for (final el in matches.where(_markedPreferred)) {
    final text = _sanitise(
      _ownText(el),
      maxLength: maxLength,
      keepNewlines: keepNewlines,
    );
    if (text != null) return text;
  }
  for (final el in matches) {
    final text = _sanitise(
      _ownText(el),
      maxLength: maxLength,
      keepNewlines: keepNewlines,
    );
    if (text != null) return text;
  }
  return null;
}

String? _childText(XmlElement parent, String wanted) {
  final el = _firstNamed(parent, wanted);
  if (el == null) return null;
  return sanitiseVCardLine(_ownText(el));
}

StructuredName? _structuredName(XmlElement? el) {
  if (el == null) return null;
  final name = StructuredName(
    prefix: _childText(el, 'PREFIX'),
    given: _childText(el, 'GIVEN'),
    additional: _childText(el, 'ADDITIONAL'),
    family: _childText(el, 'FAMILY'),
    suffix: _childText(el, 'SUFFIX'),
  );
  return name.isEmpty ? null : name;
}

PostalAddress? _address(XmlElement? el) {
  if (el == null) return null;
  final address = PostalAddress(
    poBox: _childText(el, 'POBOX'),
    // `EXTADD` is the RFC 2426 spelling; `EXTENDED` is what some exporters
    // emit and it costs nothing to read both.
    extended: _childText(el, 'EXTADD') ?? _childText(el, 'EXTENDED'),
    street: _childText(el, 'STREET'),
    locality: _childText(el, 'LOCALITY'),
    region: _childText(el, 'REGION'),
    postalCode: _childText(el, 'POSTCODE'),
    country: _childText(el, 'COUNTRY'),
  );
  return address.isEmpty ? null : address;
}

/// The inline photo, if the card carries one we can decode and trust.
///
/// `EXTVAL` is deliberately ignored. It is a URL on a stranger's server, and
/// opening somebody's profile would then make a request to an address they
/// control and we know nothing about — a beacon in every contact profile the
/// user ever opens, carrying an id they can correlate with everything else this
/// app has sent them. A photo we cannot have is a better outcome than that.
VCardPhoto? _photo(XmlElement? el) {
  if (el == null) return null;
  final binval = _firstNamed(el, 'BINVAL');
  if (binval == null) return null;
  // Whitespace is transport detail inside base64, and clients that wrap it
  // break it across lines.
  final compact = _ownText(binval).replaceAll(_base64Whitespace, '');
  if (compact.isEmpty || compact.length > maxVCardPhotoBase64) return null;
  final Uint8List bytes;
  try {
    bytes = base64Decode(compact);
  } catch (_) {
    return null;
  }
  if (bytes.isEmpty) return null;
  final mimeType = _sniffImageType(bytes);
  if (mimeType == null) return null;
  return VCardPhoto(bytes: bytes, mimeType: mimeType);
}

final RegExp _base64Whitespace = RegExp(r'\s');

/// The image type of [bytes], or null when it is not an image.
///
/// Duplicated from `sniffMimeType` in `avatar.dart` on purpose: sharing it
/// would mean the value layer importing a module that imports the database,
/// and a business card should not be able to reach the schema. When a third
/// caller needs it, the answer is a shared `lib/xmpp/image.dart`, not a third
/// copy.
///
/// Sniffed rather than declared, for the reason on [VCardPhoto.mimeType]: the
/// bytes are what get decoded, so the bytes are what decide.
String? _sniffImageType(List<int> bytes) {
  if (bytes.length >= 3 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E) {
    return 'image/png';
  }
  if (bytes.length >= 3 &&
      bytes[0] == 0xFF &&
      bytes[1] == 0xD8 &&
      bytes[2] == 0xFF) {
    return 'image/jpeg';
  }
  if (bytes.length >= 6 &&
      bytes[0] == 0x47 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x38 &&
      (bytes[4] == 0x37 || bytes[4] == 0x39) &&
      bytes[5] == 0x61) {
    return 'image/gif';
  }
  if (bytes.length >= 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return 'image/webp';
  }
  return null;
}
