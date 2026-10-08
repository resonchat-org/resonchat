// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Link previews: the out-of-band data a sender attached (XEP-0385), the link
// found in the message text, and the rules that decide whether this device may
// act on either of them.
//
// The rules are here and the fetching is not, and that split is structural
// rather than a matter of discipline: `PreviewAllowed` has a private constructor
// and the only thing that mints one is `LinkPreviewPolicy.mayFetch`. There is no
// value in this program that a caller can build, copy out of one message and
// replay against another, so a request cannot be made from here without having
// been through the policy first.
//
// Why a preview deserves that much machinery. Fetching one is a request this
// device makes, from the user's phone, to a host that the *sender* chose, on a
// schedule the sender picked, and nothing in a message bubble says a request went
// out. That is the same shape as the two things this client already refuses to
// do quietly — substituting a weaker encryption track, and acting for somebody
// the user blocked — so the same rule applies: the choice is the user's, it is
// made where they can see it, and every refusal names the rule behind it.
//
// What moxxmpp hands us today is the XEP-0066 `<x xmlns='jabber:x:oob'/>`
// element: a URL and a description, nothing else. XEP-0385's `<reference>` carries
// more — a media type, a size, a thumbnail — and none of that arrives yet, so
// `OutOfBandData` holds the fields that may be present and refuses the rest
// rather than inventing them.
//
// Depends on nothing outside `dart:`. The rules are the part worth reviewing, and
// a reviewer should not have to hold an XMPP stack in their head to read them —
// or an emulator to run the tests.

import 'dart:convert';
import 'dart:typed_data';

/// How many links in one message are considered for a preview at all.
///
/// Three is roughly what a bubble can carry without pushing the message itself
/// out of the conversation. The cap bounds how much one line of text can make
/// this phone do; it is not a judgement about what is worth showing, which is
/// `LinkPreviewPolicy.display`'s job.
const int kMaxPreviewUrls = 3;

/// Longest URL we will act on.
///
/// Refused rather than shortened. A shortened URL is a request to a different
/// address than the one that was written, and nothing in this file rewrites a
/// URL — that rule is the reason a preview cannot be a request to somewhere the
/// sender did not name.
const int kMaxUrlLength = 2048;

/// Longest title we keep from a stanza.
///
/// A title is one line of text. Something past this length is not a title, and a
/// preview card that renders a paragraph in the space where the title goes is a
/// card nobody reads. Dropping it loses nothing a reader could have used.
const int kMaxTitleLength = 4096;

/// Longest description we keep from a stanza: 3200 characters.
///
/// Longer than the title because a description is prose and a title is a label,
/// and shorter than nothing because a paragraph pasted into this field is not a
/// description. Dropped whole rather than shortened, for the reason the title is.
const int kMaxDescriptionLength = 3200;

/// Longest title rendered on a card: 120 characters.
///
/// Two lines on a phone. Separate from [kMaxTitleLength] on purpose: what we
/// keep and what we draw are different decisions, and collapsing them would mean
/// a hostile title decides how much memory we spend.
const int kMaxPreviewTitleChars = 120;

/// Longest description rendered on a card: 400 characters.
const int kMaxPreviewDescriptionChars = 400;

/// Largest thumbnail this client will decode for a card drawn inline: 2 MiB.
///
/// This is a guess, and guessing here is allowed. A threshold like this one
/// describes how much memory *this* client is willing to spend decoding an image
/// of unknown provenance on a phone. Get it wrong in either direction and the
/// user sees a card that does not draw, or a card that draws a smaller one — and
/// in both cases the message is still right there above it and the link is still
/// tappable, so the mistake is visible and the user is not worse off than before
/// the feature existed.
///
/// The same class of guess about encryption is not allowed, because there the
/// failure has no retry and no second copy: the message still goes out, it just
/// goes out readable, and nothing on either end can tell that it was downgraded
/// (`omemo/track_resolver.dart`). Guessing about pixels costs a tap. Guessing
/// about whether a message was protected costs the message.
const int kMaxInlineThumbnailBytes = 2 * 1024 * 1024;

/// A picture the sender offered for a preview.
///
/// [width], [height] and [type] are the sender's claims and nothing in this file
/// acts on them. Nothing allocates from a claimed width and height — a decoder
/// that trusts them is a decoder that can be asked for a 60000×60000 bitmap — and
/// the claimed type is not used to decide what the bytes are, because that
/// question is settled by the bytes themselves (`xmpp/avatar.dart` sniffs them
/// for the same reason).
class OutOfBandThumbnail {
  const OutOfBandThumbnail({
    required this.uri,
    this.bytes,
    this.type,
    this.width,
    this.height,
    this.size,
  });

  /// Where the thumbnail lives, exactly as the sender wrote it.
  final String uri;

  /// The bytes, when they were sent inline rather than referenced.
  final Uint8List? bytes;

  /// Claimed media type. Not trusted; see the class comment.
  final String? type;

  /// Claimed width in pixels. Not trusted; see the class comment.
  final int? width;

  /// Claimed height in pixels. Not trusted; see the class comment.
  final int? height;

  /// Claimed size in bytes. Not trusted; see the class comment.
  final int? size;

  /// The same, with the bytes handed over as a plain list.
  ///
  /// A named constructor rather than a `Uint8List` in every caller's hands: what
  /// the bytes are called is an implementation detail of the decode, and somebody
  /// assembling a preview from a list of ints should not have to know that.
  OutOfBandThumbnail.inline({
    required String uri,
    required List<int> bytes,
    String? type,
    int? width,
    int? height,
    int? size,
  }) : this(
         uri: uri,
         bytes: Uint8List.fromList(bytes),
         type: type,
         width: width,
         height: height,
         size: size,
       );

  @override
  String toString() => 'OutOfBandThumbnail($uri)';
}

/// The bytes of [thumb], or null when there are none we will decode.
///
/// Null for every failure rather than throwing: a broken data URI from the other
/// end is an ordinary thing to receive and an extraordinary thing to crash over.
/// The size limit is checked *before* decoding as well as after, because base64
/// expands by four thirds and the allocation is exactly what the limit is there
/// to avoid — measuring afterwards would miss the one case the limit exists for.
Uint8List? thumbnailBytes(OutOfBandThumbnail? thumb) {
  if (thumb == null) return null;
  final inline = thumb.bytes;
  if (inline != null) {
    return inline.length <= kMaxInlineThumbnailBytes ? inline : null;
  }
  final uri = thumb.uri.trim();
  if (!uri.toLowerCase().startsWith('data:')) return null;
  final comma = uri.indexOf(',');
  if (comma < 0) return null;
  // Only base64 payloads. A `data:text/plain,…` URI is text somebody wrote, and
  // handing it to an image decoder helps nobody.
  if (!uri.substring(5, comma).contains('base64')) return null;
  final payload = uri.substring(comma + 1);
  if (payload.length > (kMaxInlineThumbnailBytes * 3) ~/ 2 + 4) return null;
  try {
    final decoded = base64Decode(payload);
    if (decoded.length > kMaxInlineThumbnailBytes) return null;
    return Uint8List.fromList(decoded);
  } catch (_) {
    // Malformed base64. `%%%` in a data URI lands here rather than in the
    // decoder, which is the entire reason this is a try.
    return null;
  }
}

/// What the sender attached to the message (XEP-0385 out-of-band data).
///
/// Built through [tryParse] only, so every instance has been through the same
/// checks and no caller can construct one that skipped them.
class OutOfBandData {
  const OutOfBandData._({
    required this.url,
    this.title,
    this.description,
    this.type,
    this.size,
    this.thumbnail,
  });

  /// The address, exactly as written.
  final String url;

  final String? title;
  final String? description;

  /// Claimed media type of what the URL points at. Not trusted for the same
  /// reason a thumbnail's is not.
  final String? type;

  /// Claimed size of what the URL points at, in bytes. Null when absent, and
  /// null when the claim is negative: a size that cannot be true must not reach
  /// the display rules, where "small" wins over "unknown" and a wrong guess
  /// about a number the sender typed decides what gets drawn.
  final int? size;

  final OutOfBandThumbnail? thumbnail;

  /// Reads the element, or returns null when there is nothing here we may act on.
  ///
  /// Null — rather than an instance with a blank URL — because every field of
  /// this type is only useful with an address to attach it to, and an instance
  /// with an unusable one would push the decision "can we do anything with
  /// this?" out to every call site.
  static OutOfBandData? tryParse({
    String? url,
    String? title,
    String? description,
    String? type,
    int? size,
    OutOfBandThumbnail? thumbnail,
  }) {
    final clean = _trimToNull(url);
    if (clean == null || !isFetchableUrl(clean)) return null;
    return OutOfBandData._(
      url: clean,
      title: _shortenToNull(title, kMaxTitleLength),
      description: _shortenToNull(description, kMaxDescriptionLength),
      type: _trimToNull(type),
      size: (size != null && size >= 0) ? size : null,
      thumbnail: thumbnail,
    );
  }

  @override
  String toString() => 'OutOfBandData($url)';
}

/// Everything the UI shows for one link.
///
/// Private constructor for the same reason as [OutOfBandData]: the rules that
/// decide whether a field is filled in live in [mergePreview], and a second
/// constructor would be a second set of them.
class LinkPreview {
  const LinkPreview._({
    required this.url,
    this.title,
    this.description,
    this.type,
    this.size,
    this.thumbnail,
    this.urlFromStanza = false,
    this.announcedUrl,
  });

  /// The address this preview is *about*.
  ///
  /// When the message body carried a link, this is that link and nothing else —
  /// including when the sender's element names a different one. See
  /// [mergePreview].
  final String url;

  final String? title;
  final String? description;
  final String? type;
  final int? size;
  final OutOfBandThumbnail? thumbnail;

  /// True when no link was found in the body and this address came from the
  /// out-of-band element.
  ///
  /// Load-bearing, and the reason [LinkPreviewPolicy.display] never draws such a
  /// preview inline: the body is what the message is *about*, and a card drawn
  /// next to a sentence that never mentioned the address puts somebody's site
  /// into the reader's attention without the text ever having claimed it.
  final bool urlFromStanza;

  /// The address the element named, when it is not the one in [url], or null.
  ///
  /// Kept rather than discarded so the disagreement is visible. Silently
  /// preferring one of two addresses is how a client ends up fetching something
  /// the reader cannot account for.
  final String? announcedUrl;

  /// True when there is something to draw that the message text does not already
  /// say.
  ///
  /// A card holding only a URL is the message again, and a card that repeats the
  /// message costs the reader a screen to learn nothing.
  bool get hasSomethingToShow =>
      thumbnail != null ||
      (title != null && title!.isNotEmpty) ||
      (description != null && description!.isNotEmpty);

  /// The title, cut to [kMaxPreviewTitleChars].
  ///
  /// The stored value is never shortened — it is what the sender sent, and the
  /// bubble needs something to draw and something to keep.
  String get displayTitle => _cap(title, kMaxPreviewTitleChars);

  /// The description, cut to [kMaxPreviewDescriptionChars].
  String get displayDescription =>
      _cap(description, kMaxPreviewDescriptionChars);

  /// This preview with anything [fetched] knew and this one did not.
  ///
  /// Field-by-field, with the fetched value winning where it has one — a real
  /// page's title is a better title than the sender's guess, and this is the
  /// whole reason a fetch happens.
  ///
  /// The fallback exists because the sender's announcement is not decoration.
  /// XEP-0385's purpose is that the sender tells us the title *so that we do not
  /// have to fetch*, and a fetcher that answers with a page carrying no metadata
  /// at all must not delete what we were given for free. The failure it prevents
  /// is a card that got emptier the more successfully we fetched — a link with a
  /// title that silently became a bare address, which the module's own
  /// [hasSomethingToShow] then refuses to draw, so the fetch made the feature
  /// worse rather than better.
  ///
  /// [urlFromStanza] and [announcedUrl] are carried over unchanged rather than
  /// taken from the fetch: they describe how the address was obtained, and a
  /// fetcher that returned a different address is a bug to be surfaced, not
  /// absorbed here.
  LinkPreview withFallback(LinkPreview fetched) {
    if (identical(fetched, this)) return this;
    return LinkPreview._(
      url: fetched.url,
      title: _or(fetched.title, title),
      description: _or(fetched.description, description),
      type: _or(fetched.type, type),
      size: fetched.size ?? size,
      thumbnail: fetched.thumbnail ?? thumbnail,
      urlFromStanza: urlFromStanza,
      announcedUrl: announcedUrl,
    );
  }

  /// The first value that carries something, so an empty string never counts as
  /// "the sender told us".
  ///
  /// Empty rather than null: a fetcher that parses a `<title></title>` into `''`
  /// would otherwise win every comparison and produce a blank title where the
  /// sender's was sitting right there.
  static String? _or(String? preferred, String? fallback) {
    if (preferred != null && preferred.isNotEmpty) return preferred;
    if (fallback != null && fallback.isNotEmpty) return fallback;
    return preferred ?? fallback;
  }

  @override
  String toString() => 'LinkPreview($url)';
}

/// Combines what the sender announced with what the body actually says.
///
/// Returns null when neither exists, or when the announced address is not one we
/// would act on.
///
/// The body's URL wins, and it wins even when the element names a different one.
/// Two reasons, and the first is the one that decides it:
///
///   * The element travels **outside** the encrypted payload. moxxmpp's OOB
///     handler reads a child of the incoming stanza, and the body is the thing
///     the OMEMO layer decrypts — so for an encrypted message the URL in the
///     element is a claim in the clear, not something the ciphertext vouched
///     for. A link the body carried is authenticated by the encryption; a link
///     that only the element carried is not, and this file refuses to act on
///     unauthenticated claims in the one place where acting on them is invisible.
///
///   * A title or description that was sent for a *different* address is the most
///     valuable thing anybody can put in a preview: it is the text that will read
///     like our own words about their link. So the enrichment is dropped rather
///     than pinned next to a link it was not written for, and the disagreement
///     is preserved in [LinkPreview.announcedUrl] so the UI can show it instead
///     of quietly resolving it.
///
/// Both inputs are checked again here. A merge is where wire data meets the
/// rules, and the body is attacker text; a function that trusted its caller's
/// validation would be trusting whoever called it.
///
/// [announced] is optional rather than required because "this stanza carried no
/// oob element" is the ordinary case for most messages, and a caller that had to
/// write `announced: null` to say so would eventually stop noticing the argument
/// altogether. It is unambiguous against the alternative: a *present* element
/// that disagrees with the body sets [LinkPreview.announcedUrl], while `null`
/// leaves it unset, so no caller can confuse "no claim was made" with "a claim
/// was made and lost".
LinkPreview? mergePreview({
  required String? detectedUrl,
  OutOfBandData? announced,
}) {
  final detected = _trimToNull(detectedUrl);
  if (detected != null && isFetchableUrl(detected)) {
    final agrees = announced != null && announced.url == detected;
    if (agrees) {
      return LinkPreview._(
        url: detected,
        title: announced.title,
        description: announced.description,
        type: announced.type,
        size: announced.size,
        thumbnail: announced.thumbnail,
        urlFromStanza: false,
      );
    }
    return LinkPreview._(
      url: detected,
      urlFromStanza: false,
      announcedUrl: announced?.url,
    );
  }
  if (announced == null) return null;
  return LinkPreview._(
    url: announced.url,
    title: announced.title,
    description: announced.description,
    type: announced.type,
    size: announced.size,
    thumbnail: announced.thumbnail,
    urlFromStanza: true,
  );
}

/// The preview for the first link in [body], if there is one.
///
/// What the inbound path wants: scan, merge, take the first candidate. First,
/// because this file has no way to know which of somebody's links the message is
/// about, and picking by a heuristic would be the client choosing which link to
/// act on.
LinkPreview? previewForBody(
  String body, {
  OutOfBandData? announced,
  int limit = kMaxPreviewUrls,
}) {
  final scan = scanUrls(body, limit: limit);
  if (scan.links.isEmpty) return null;
  return mergePreview(detectedUrl: scan.links.first, announced: announced);
}

/// The links in one message body, split by what we will do with them.
///
/// Three lists rather than one, because the three are answered differently and
/// the difference is the point of the type.
///
/// A `> ` line is somebody else's words. It is text that the person this user is
/// talking to copied in order to quote it, and the URL in it belongs to whoever
/// wrote the quoted message — a third party this user never chose to hear from.
/// Fetching it makes this phone contact a host on a stranger's schedule, and
/// nothing in the bubble says a request went out. So those links are counted and
/// reported and never previewed; the user can still tap one, which is visible,
/// deliberate, and theirs.
///
/// A backticked link is the sender's own text, so it is kept — but only as
/// something to ask for. A URL in a fence is text that *mentions* an address: a
/// sample endpoint, a log line, a signature, the URL of the blog post somebody is
/// quoting the code from. Attaching a preview to it says "this is what they are
/// sharing", and they were not sharing that.
///
/// Code-span links do not consume the [limit]. The cap exists to bound automatic
/// fetching, and a link that will only ever be fetched after a tap must not spend
/// the budget of one that will be fetched on arrival — otherwise a message with
/// three sample URLs in a fence ahead of its real one gets no preview at all,
/// which is a strange thing to have done to somebody for free.
class UrlScan {
  UrlScan({
    required List<String> links,
    required List<String> insideCode,
    required List<String> insideQuote,
    required this.distinctFound,
    required this.droppedForCap,
  }) : links = List.unmodifiable(links),
       insideCode = List.unmodifiable(insideCode),
       insideQuote = List.unmodifiable(insideQuote);

  /// The message's own links: in the order written, de-duplicated, capped at
  /// [scanUrls]'s `limit`. The only list a preview may be fetched for without
  /// the user asking first.
  final List<String> links;

  /// Links inside backticks or a fenced block. Never fetched automatically.
  final List<String> insideCode;

  /// Links inside a `> ` quoted line. Never previewed by this client at all.
  final List<String> insideQuote;

  /// How many distinct links the body held, before any cap and including the two
  /// lists that are not acted on.
  final int distinctFound;

  /// True when links were left out because of the cap.
  ///
  /// Exists so the truncation can be *said*. The cap keeps the first links in
  /// reading order, never the last: the first link is the one a message is about
  /// when a person writes one, and a rule that dropped it in favour of the tail
  /// would make "the link I sent first has no preview" the ordinary outcome, which
  /// reads as a bug in the client rather than as a limit — and the reader has no
  /// way to tell those two apart. So what was left out is counted here rather
  /// than disappeared.
  final bool droppedForCap;

  /// True when there is nothing to preview.
  bool get isEmpty => links.isEmpty;

  @override
  String toString() =>
      'UrlScan(${links.length} links, '
      '${insideCode.length} in code, ${insideQuote.length} in quotes, '
      '$distinctFound found)';
}

/// Finds the links in [body].
///
/// An empty body yields nothing at all: not an empty link, and not a link made of
/// the whitespace. `''.split('\n')` is `['']`, which is a line, and a line is
/// where links are found — so a body with nothing in it would otherwise produce
/// a scan rather than nothing.
///
/// Only `http` and `https` are recognised, and `www.`-style text is not a link
/// at all. A preview has to fetch exactly the address that is written in the
/// message, because the address is the only part of it a reader can check by
/// eye; completing `www.example.com` into `https://www.example.com` means making
/// a request to somewhere the sender did not name and showing the result under a
/// line that does not contain it. A URI that is not an HTTP address — `xmpp:`,
/// `mailto:`, `geo:` — is a link the reader can act on and is not something this
/// device should fetch behind their back.
UrlScan scanUrls(String body, {int limit = kMaxPreviewUrls}) {
  if (body.isEmpty) {
    return UrlScan(
      links: const [],
      insideCode: const [],
      insideQuote: const [],
      distinctFound: 0,
      droppedForCap: false,
    );
  }

  final links = <String>[];
  final insideCode = <String>[];
  final insideQuote = <String>[];
  final seenLink = <String>{};
  final seenCode = <String>{};
  final seenQuote = <String>{};
  var distinctLinks = 0;
  var fenced = false;

  for (final line in body.split('\n')) {
    // A fence line toggles and is never itself a link. Three backticks and an
    // info string is the whole of the convention that survives in a body which
    // was never rendered as Markdown.
    if (line.trimLeft().startsWith('```')) {
      fenced = !fenced;
      continue;
    }
    // Everything inside a fence is code, including lines that look like
    // quoted prose: inside a fence `>` is an operator, not a quote marker.
    if (fenced) {
      for (final found in _urlsIn(line)) {
        if (seenCode.add(_dedupeKey(found.url))) insideCode.add(found.url);
      }
      continue;
    }
    if (_isQuoted(line)) {
      for (final found in _urlsIn(line)) {
        if (seenQuote.add(_dedupeKey(found.url))) insideQuote.add(found.url);
      }
      continue;
    }
    final spans = _inlineCode(line);
    for (final found in _urlsIn(line)) {
      if (_inside(spans, found.start)) {
        if (seenCode.add(_dedupeKey(found.url))) insideCode.add(found.url);
        continue;
      }
      if (!seenLink.add(_dedupeKey(found.url))) continue;
      distinctLinks++;
      if (links.length < limit) links.add(found.url);
    }
  }

  return UrlScan(
    links: links,
    insideCode: insideCode,
    insideQuote: insideQuote,
    distinctFound: distinctLinks + insideCode.length + insideQuote.length,
    droppedForCap: distinctLinks > links.length,
  );
}

/// The facts about one message that the rules are allowed to look at.
///
/// A type rather than four booleans at each call site so that adding a reason a
/// preview must not be fetched is a compile error everywhere, rather than a
/// defaulted `false` somebody forgets — which is the way a security check stops
/// being enforced.
///
/// Every flag defaults to false, and that is deliberate: a plain message from an
/// unblocked contact with previews on is the case the user expects, and it should
/// be the one that takes no arguments.
class PreviewContext {
  const PreviewContext({
    required this.sender,
    this.blocked = false,
    this.undecryptable = false,
  });

  /// Who wrote it.
  final String sender;

  /// The conversation is blocked (see `blocking.dart`).
  final bool blocked;

  /// The message arrived but could not be opened, so nothing we hold is what
  /// the sender wrote.
  final bool undecryptable;
}

/// The closed vocabulary of [PreviewRefused.reason].
///
/// Every refusal names one of these. "No preview appeared" is indistinguishable
/// from "this client has a bug" unless the app can say which rule refused, and a
/// suppression nobody wrote down is the thing that gets reported as a feature.
enum PreviewRefusal {
  /// There is no address we will act on.
  noUrl,

  /// The message had no sender we can attribute it to.
  unknownSender,

  /// The conversation is blocked.
  senderBlocked,

  /// The message could not be opened.
  unreadableMessage,

  /// The user has link previews switched off.
  previewsDisabled,
}

/// What a refusal says to the user.
///
/// Kept beside the enum rather than in the widgets so the wording can be read,
/// and tested, without rendering anything — and because in this feature the
/// wording *is* part of the promise. "No preview" reads as an absence of
/// information; these read as a decision the app made, which is what it is.
extension PreviewRefusalWording on PreviewRefusal {
  String get title => switch (this) {
    PreviewRefusal.noUrl => 'This link cannot be previewed',
    PreviewRefusal.unknownSender => 'This message has no sender',
    PreviewRefusal.senderBlocked => 'No previews from this contact',
    PreviewRefusal.unreadableMessage => 'This message could not be opened',
    PreviewRefusal.previewsDisabled => 'Link previews are off',
  };

  /// The consequence, in terms of what happens on the network.
  String get consequence => switch (this) {
    PreviewRefusal.noUrl =>
      'The address in this message is not one this app will fetch.',
    PreviewRefusal.unknownSender =>
      'This app does not fetch links from a message it cannot attribute to '
          'anybody.',
    PreviewRefusal.senderBlocked =>
      'Opening a link from somebody you blocked would contact a third party '
          'on their behalf, without telling you.',
    PreviewRefusal.unreadableMessage =>
      'The address comes from a message this device could not decrypt, so '
          'we will not visit it.',
    PreviewRefusal.previewsDisabled =>
      'Turn link previews on in Settings to fetch this.',
  };
}

/// The answer to "may this device fetch this?".
sealed class PreviewVerdict {
  /// Const so an approval can be built in a `const` context.
  ///
  /// Not decoration: `PreviewAllowed._` is private to this library precisely so
  /// that only `LinkPreviewPolicy.mayFetch` can mint one, and a private
  /// constructor that cannot be const is a constructor nobody can use in a const
  /// list — which is how the tests below pin the "exactly one place" claim.
  const PreviewVerdict();
}

/// Permission to fetch exactly [url], and nothing else.
///
/// Constructible only by `LinkPreviewPolicy.mayFetch`, which is the whole design:
/// the approval and the address are one object, so no caller can approve a
/// request and then send a different one, and no caller can hold an approval
/// from one message and use it against another.
final class PreviewAllowed extends PreviewVerdict {
  const PreviewAllowed._(this.url);

  /// The one address this approval covers.
  final String url;

  @override
  String toString() => 'PreviewAllowed($url)';
}

/// No. [reason] is the rule that said so.
final class PreviewRefused extends PreviewVerdict {
  const PreviewRefused(this.reason);

  final PreviewRefusal reason;

  @override
  String toString() => 'PreviewRefused($reason)';
}

/// How much of a preview to show without being asked.
enum PreviewDisplay {
  /// Nothing at all.
  none,

  /// A button the reader has to press. The fetch still needs the policy; being
  /// offered a button is not approval.
  onDemand,

  /// Drawn with the message.
  inline,
}

/// The rules, plus the user's switch.
///
/// Same rules in both directions. A link this user sent is a request to a third
/// party from their phone, and the reason not to make it without being asked is
/// the same whichever side of the conversation the words came from; a rule that
/// previews what we sent and not what we received is a rule about the direction
/// of the message rather than about who chose the address.
class LinkPreviewPolicy {
  const LinkPreviewPolicy({this.previewsEnabled = false});

  /// The user's switch.
  ///
  /// Off by default, which is against the fashion and is the point. Everything
  /// else this client refuses to do on somebody's behalf it refuses *before*
  /// being asked; a feature whose whole job is to request a host a stranger
  /// typed, from the user's phone, has no business starting switched on. The
  /// cost of being wrong here is a card that does not appear, which the user
  /// fixes by turning a switch in Settings — the cost of the other default is
  /// requests nobody agreed to, which nothing in the interface offers them a way
  /// to see. Compare `globalTrackProvider`, which resolves an unreadable value
  /// to the safer setting rather than the more convenient one.
  ///
  /// A switch, not a default the caller is meant to override. It refuses in both
  /// directions — nothing is fetched automatically and nothing is drawn —
  /// because a setting with one path around it is a setting that will be walked
  /// around.
  final bool previewsEnabled;

  /// May [url] be fetched, for the message described by [context]?
  ///
  /// Order matters and is the policy:
  ///
  ///  1. An address we will not act on. Saying "this contact is blocked" about a
  ///     malformed element attaches the user's own safety decision to somebody
  ///     else's typo, and a refusal about a URL we cannot read says nothing about
  ///     anybody.
  ///  2. No sender. "We do not act for somebody" needs a somebody, and a stanza
  ///     with no `from` is not a message from a person — it is a message from
  ///     whoever can write to the server's routing. There is nobody to hold a
  ///     promise to, so there is nothing to refuse on their behalf.
  ///  3. Blocked. The promise in `blocking.dart` is that a blocked sender cannot
  ///     make this device act as a reader or a signer for them, and a preview is
  ///     the strongest version of that: a request to a third party, from the
  ///     user's phone, on the sender's schedule, that leaves no trace in the
  ///     bubble. Blocking is not defeated by a hyperlink.
  ///  4. Undecryptable. A different failure from blocked, and the reason it is a
  ///     separate case rather than the same one: blocked is about *the person*
  ///     and undecryptable is about *the bytes*. Fixing one must not silently
  ///     unlock the other — a key arriving late and decrypting a message that was
  ///     already stored says nothing about who is on the block list, and an
  ///     unblocked contact whose message we could not open is still a message we
  ///     did not read.
  ///  5. The switch.
  ///
  /// The address is checked again here even though [scanUrls] and
  /// [OutOfBandData.tryParse] already checked it: this is the last gate before a
  /// request exists, and a policy that trusts its caller's validation is a policy
  /// whose safety depends on every caller having remembered.
  PreviewVerdict mayFetch({
    required PreviewContext context,
    required String url,
  }) {
    final address = _trimToNull(url);
    if (address == null || !isFetchableUrl(address)) {
      return const PreviewRefused(PreviewRefusal.noUrl);
    }
    if (context.sender.trim().isEmpty) {
      return const PreviewRefused(PreviewRefusal.unknownSender);
    }
    if (context.blocked) {
      return const PreviewRefused(PreviewRefusal.senderBlocked);
    }
    if (context.undecryptable) {
      return const PreviewRefused(PreviewRefusal.unreadableMessage);
    }
    if (!previewsEnabled) {
      return const PreviewRefused(PreviewRefusal.previewsDisabled);
    }
    return PreviewAllowed._(address);
  }

  /// [mayFetch] for an already-merged preview.
  PreviewVerdict mayFetchPreview({
    required PreviewContext context,
    required LinkPreview preview,
  }) => mayFetch(context: context, url: preview.url);

  /// How much of [preview] to draw without the reader asking.
  ///
  /// Every refusal in [mayFetch] is a refusal to draw as well, for the same
  /// reasons: a card is a request to a host the sender chose, and drawing one
  /// means making it.
  ///
  /// Beyond that, a card is only drawn when it says something the message does
  /// not, and never over a link that came from the element rather than the body
  /// ([LinkPreview.urlFromStanza]) or from inside a code span. Both of those go
  /// to [PreviewDisplay.onDemand], which is not a weaker version of `inline`: the
  /// fetch behind it goes through [mayFetch] exactly as before, and the only
  /// thing that changed is that a person has to press something first.
  PreviewDisplay display({
    required PreviewContext context,
    required LinkPreview preview,
    bool fromCodeSpan = false,
  }) {
    if (context.blocked) return PreviewDisplay.none;
    if (context.undecryptable) return PreviewDisplay.none;
    if (!previewsEnabled) return PreviewDisplay.none;
    if (!isFetchableUrl(preview.url)) return PreviewDisplay.none;
    if (fromCodeSpan) return PreviewDisplay.onDemand;
    // The body never mentioned this address, so a picture drawn under it is a
    // picture of something the sender chose and the message did not.
    if (preview.urlFromStanza) return PreviewDisplay.onDemand;
    if (!preview.hasSomethingToShow) return PreviewDisplay.onDemand;
    return _drawableInline(preview)
        ? PreviewDisplay.inline
        : PreviewDisplay.onDemand;
  }
}

/// Whether a card's picture can be drawn here, within [kMaxInlineThumbnailBytes].
///
/// The claim and the bytes disagree often enough that the claim has to lose: the
/// limit exists to bound what this client *allocates*, and only the bytes say
/// what that is. A sender who claims 1 KB and sends 40 MiB gets the 40 MiB
/// treatment; a sender who claims 40 MiB and sends 1 KB does not get made to
/// press a button on the strength of a number they typed.
bool _drawableInline(LinkPreview preview) {
  final thumb = preview.thumbnail;
  if (thumb == null) return true;
  return thumbnailBytes(thumb) != null;
}

/// The only way to reach the contents of a link.
///
/// [fetch] takes a [PreviewAllowed] and nothing else, and that type cannot be
/// built outside this file — so there is no value in this program a caller could
/// mint, copy out of one message, or replay against another. The approval and
/// the address arrive together and are the same object.
///
/// Two things an implementation must not do, both of which this shape is meant to
/// make awkward rather than merely discouraged:
///
///   * Fetch a second address under one approval. A thumbnail reference is its
///     own URI, on a host chosen separately from the page, so it needs its own
///     `mayFetch` call with the same context — and that call refuses it in
///     exactly the cases above, because a blocked sender's thumbnail is still a
///     blocked sender's request.
///   * Keep the approval. It is per message and per address. A fetcher that
///     caches one and replays it later has turned "may we fetch this" into "we
///     fetched this once", which is the mistake the blocked rule exists to stop.
abstract class LinkPreviewFetcher {
  Future<LinkPreview> fetch(PreviewAllowed approved);
}

/// Fetches the preview for the first link in [body], if every rule allows it.
///
/// This is the automatic path, and only a card that would be drawn inline is
/// fetched through it. An on-demand preview stays unfetched until somebody
/// presses its button — which is the entire difference between the two, so it
/// cannot be relaxed here: a caller that fetched an on-demand preview would be
/// making the request the button exists to prevent, and doing it from a function
/// whose name does not mention buttons.
///
/// Null for every refusal, and null rather than an exception, because "we did not
/// fetch this" and "we could not fetch this" lead a bubble to the same empty
/// space and treating them differently would mean an error state for something
/// that is an ordinary, and mostly correct, outcome.
///
/// The ordering is done here rather than left to the caller because the caller's
/// version of it would be the version that forgets: fetch the card, then notice
/// it is not drawn.
Future<LinkPreview?> loadPreview({
  required LinkPreviewPolicy policy,
  required LinkPreviewFetcher fetcher,
  required String body,
  required PreviewContext context,
  OutOfBandData? announced,
  int limit = kMaxPreviewUrls,
}) async {
  final preview = previewForBody(body, announced: announced, limit: limit);
  if (preview == null) return null;
  if (policy.display(context: context, preview: preview) !=
      PreviewDisplay.inline) {
    return null;
  }
  // Pattern-matched rather than cast: `mayFetch` returns the sealed base, and
  // the only way to reach the fetcher with the address it approved is to hold
  // the `PreviewAllowed` itself. Passing a `PreviewVerdict` and letting the
  // fetcher read `.url` off it would put the address on the base class, which
  // is exactly the widening that lets a caller fetch something it was not
  // approved for.
  return switch (policy.mayFetch(context: context, url: preview.url)) {
    // The whole `PreviewAllowed`, not the url it carries: handing the fetcher a
    // bare string would mean the approval is checked once and then thrown away,
    // so the fetcher would be free to fetch anything it liked with it.
    PreviewAllowed allowed => (await fetcher.fetch(
      allowed,
    )).withFallback(preview),
    PreviewRefused() => null,
  };
}

/// Whether [url] is an address this client will fetch at all.
///
/// The scheme has to be one we can request with a plain HTTP client. `file:` is a
/// read of the user's own disk, `data:` is a decode of whatever the sender
/// packed in, and neither is a preview.
///
/// A URL carrying `@` before the host is refused rather than cleaned. That is the
/// one shape where the text a person reads and the address the request goes to can
/// disagree without the text looking wrong: `https://archive.example@tracker.example`
/// reads as archive.example to anybody skimming it. Stripping the userinfo would
/// leave a URL we fetched that is not the URL that was written, and this file does
/// not rewrite URLs.
///
/// Refused above [kMaxUrlLength] for the same reason: shortening one is the same
/// sin with less code.
///
/// Refuses addresses on this device's own network outright. A preview is a
/// request from a phone to a host a stranger typed, and `http://192.168.1.1/` is
/// the router in the room the phone is sitting in; `http://127.0.0.1:8080/` is a
/// development server; `http://169.254.169.254/` is the cloud metadata endpoint,
/// which hands out credentials. People do paste LAN addresses to each other, and
/// this will not preview them: the cost is a link that does not grow a card, and
/// the alternative is a stranger's one-line message reaching into the user's
/// network from the user's own pocket.
///
/// **This is not the SSRF defence, and it must not be read as one.** A *name* that
/// resolves to one of those addresses is not caught here, because a string cannot
/// know what a name resolves to. Whoever implements the fetcher has to check the
/// address it actually connected to, after resolving and after every redirect —
/// otherwise a hostname is an unchecked request, and a redirect is the same
/// request one hop later. That check is not optional and it does not live in this
/// file, which is precisely why it is written down here.
bool isFetchableUrl(String url) {
  final lower = url.toLowerCase();
  if (!lower.startsWith('http://') && !lower.startsWith('https://'))
    return false;
  if (url.length > kMaxUrlLength) return false;

  final schemeEnd = lower.indexOf('://') + 3;
  var host = '';
  var i = schemeEnd;
  for (; i < url.length; i++) {
    final ch = url[i];
    if (ch == '/' || ch == '?' || ch == '#') break;
    host += ch;
  }
  if (host.isEmpty) return false;
  // Userinfo, before the host that actually gets the request.
  if (host.contains('@')) return false;
  return !isPrivateHost(host);
}

/// Whether [host] is an address on this device's own network.
///
/// A name is not an answer: `localhost` is refused because it is the one name
/// whose meaning is fixed by every machine that resolves it, and everything else
/// has to be judged by the fetcher after it resolves.
bool isPrivateHost(String host) {
  if (host.startsWith('[')) {
    // An IPv6 literal, kept with its brackets because that is the only form an
    // address has to be in to be looked up. The port comes *after* the closing
    // bracket, so `[::1]:8080` has to be reduced to `[::1]` before it can be
    // judged — testing the whole authority against `[::1]` would wave the one
    // address on this loopback straight through.
    final close = host.indexOf(']');
    if (close < 0) return true;
    final literal = host.substring(0, close + 1).toLowerCase();
    if (literal == '[::1]' || literal == '[::]') return true;
    if (literal.startsWith('[fe80:')) return true;
    if (literal.startsWith('[fc') || literal.startsWith('[fd')) return true;
    if (literal.startsWith('[::ffff:')) {
      final mapped = literal.substring('[::ffff:'.length, literal.length - 1);
      return isPrivateHost(mapped);
    }
    return false;
  }
  final colon = host.lastIndexOf(':');
  final name = colon >= 0 ? host.substring(0, colon) : host;
  if (name.isEmpty) return true;
  if (name.toLowerCase() == 'localhost') return true;

  final octets = name.split('.');
  if (octets.length != 4) return false;
  final values = <int>[];
  for (final octet in octets) {
    final value = int.tryParse(octet);
    if (value == null || value < 0 || value > 255) return false;
    // A dotted quad with leading zeros parses differently in different
    // resolvers, so refuse it rather than guess which one this phone uses.
    if (octet.length > 1 && octet.startsWith('0')) return true;
    values.add(value);
  }
  final a = values[0];
  final b = values[1];
  if (a == 0 || a == 127) return true;
  if (a == 10) return true;
  if (a == 172 && b >= 16 && b <= 31) return true;
  if (a == 192 && b == 168) return true;
  // Link-local, and with it the cloud metadata endpoint.
  if (a == 169 && b == 254) return true;
  // Carrier-grade NAT, and multicast/reserved space nobody previews from.
  if (a == 100 && b >= 64 && b <= 127) return true;
  if (a >= 224) return true;
  return false;
}

/// The scheme, and nothing else about a URL.
///
/// A literal pattern with no repetition, so a body made of angle brackets and
/// percent signs costs the same as a body of prose: there is no input here that
/// makes the scan take longer than the length of the line it is reading.
final RegExp _scheme = RegExp('https?://', caseSensitive: false);

/// Characters that end a URL run.
///
/// ASCII only, on purpose. A non-ASCII character at the end of a run is left in
/// rather than guessed at, because guessing at the tail of an address is how a
/// request ends up going somewhere the sender did not name. The same rule refuses
/// the host-relative shapes people actually get wrong: `xhttps://example.com` and
/// `.https://example.com` are longer tokens, not URLs.
const String _terminators = '<>"\'`\\^{}| ';

final RegExp _tokenChar = RegExp(r'[A-Za-z0-9._~+%-]');

final RegExp _quotePrefix = RegExp(r'^ {0,3}> ?');

/// Punctuation that is almost never part of the address a person meant.
const String _tailPunctuation = '.,;:!?*_~\'"-…';

/// The URLs in one line, with where each one starts.
List<({String url, int start})> _urlsIn(String line) {
  final found = <({String url, int start})>[];
  for (final match in _scheme.allMatches(line)) {
    final start = match.start;
    if (start > 0 && _tokenChar.hasMatch(line[start - 1])) continue;
    var end = match.end;
    while (end < line.length && !_isTerminator(line[end])) {
      end++;
    }
    final url = _trimTail(line.substring(start, end));
    if (!isFetchableUrl(url)) continue;
    found.add((url: url, start: start));
  }
  return found;
}

bool _isTerminator(String ch) => ch.trim().isEmpty || _terminators.contains(ch);

/// Cuts the characters after a URL that belong to the sentence around it.
///
/// Balanced brackets stay: `https://en.wikipedia.org/wiki/Foo_(bar)` is one
/// address, and stopping at the first `)` turns it into a 404 the reader cannot
/// see the cause of. An unbalanced one goes, because it is punctuation.
///
/// The bracket depths are counted once over the whole run and adjusted as the
/// tail comes off, rather than recounted per character. A body that is nothing
/// but a URL followed by ten thousand closing brackets is a sentence anyone can
/// send, and the version of this that recounts would take minutes on it.
String _trimTail(String raw) {
  var parens = 0;
  var squares = 0;
  var braces = 0;
  for (var i = 0; i < raw.length; i++) {
    final ch = raw[i];
    if (ch == '(') {
      parens++;
    } else if (ch == ')') {
      parens--;
    } else if (ch == '[') {
      squares++;
    } else if (ch == ']') {
      squares--;
    } else if (ch == '{') {
      braces++;
    } else if (ch == '}') {
      braces--;
    }
  }

  var end = raw.length;
  while (end > 0) {
    final ch = raw[end - 1];
    if (_tailPunctuation.contains(ch)) {
      end--;
      continue;
    }
    if (ch == ')' && parens < 0) {
      parens++;
      end--;
      continue;
    }
    if (ch == ']' && squares < 0) {
      squares++;
      end--;
      continue;
    }
    if (ch == '}' && braces < 0) {
      braces++;
      end--;
      continue;
    }
    break;
  }
  return raw.substring(0, end);
}

bool _isQuoted(String line) => _quotePrefix.hasMatch(line);

/// The code spans in one line, as half-open ranges.
///
/// An unmatched run of backticks is treated as opening a span that never closes,
/// and everything after it on the line is inside it. The other reading — an
/// unmatched delimiter is literal, as CommonMark has it — is right about
/// rendering and wrong about this decision: the cost of being wrong this way is a
/// preview missing, and the cost of being wrong the other way is a request to a
/// host nobody chose, made on the strength of one stray character.
List<(int, int)> _inlineCode(String line) {
  final spans = <(int, int)>[];
  int? openAt;
  var i = 0;
  while (i < line.length) {
    if (line[i] != '`') {
      i++;
      continue;
    }
    var j = i;
    while (j < line.length && line[j] == '`') {
      j++;
    }
    if (openAt == null) {
      openAt = i;
    } else {
      spans.add((openAt, j));
      openAt = null;
    }
    i = j;
  }
  if (openAt != null) spans.add((openAt, line.length));
  return spans;
}

bool _inside(List<(int, int)> spans, int index) {
  for (final (start, end) in spans) {
    if (index >= start && index < end) return true;
  }
  return false;
}

/// The key two occurrences of one address share.
///
/// Scheme and host case-folded, fragment dropped. Both are needed to catch the
/// same link pasted twice, which is the case worth catching: two previews for one
/// page is two requests to one host for one thing. The path and query keep their
/// case — they are case-sensitive, and folding them merges two different
/// documents. The first occurrence is the one kept, because it is the one the
/// surrounding sentence describes.
String _dedupeKey(String url) {
  final lower = url.toLowerCase();
  var i = lower.indexOf('://') + 3;
  while (i < url.length) {
    final ch = lower[i];
    if (ch == '/' || ch == '?' || ch == '#') break;
    i++;
  }
  // From the end of the authority, so a `#` cannot cut the key short inside it.
  final rest = url.substring(i);
  final fragment = rest.indexOf('#');
  return lower.substring(0, i) +
      (fragment < 0 ? rest : rest.substring(0, fragment));
}

String? _trimToNull(String? text) {
  if (text == null) return null;
  final trimmed = text.trim();
  return trimmed.isEmpty ? null : trimmed;
}

String? _shortenToNull(String? text, int max) {
  final trimmed = _trimToNull(text);
  if (trimmed == null || trimmed.length <= max) return trimmed;
  return null;
}

String _cap(String? text, int max) {
  final trimmed = _trimToNull(text);
  if (trimmed == null) return '';
  if (trimmed.length <= max) return trimmed;
  return '${trimmed.substring(0, max - 1).trimRight()}…';
}
