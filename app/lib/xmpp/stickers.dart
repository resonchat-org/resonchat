// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Stickers (XEP-0449, `urn:xmpp:stickers:0`).
//
// Packs live on the PEP node `urn:xmpp:stickers:0`, the sibling of native
// bookmarks, and sending one is XEP-0447 stateless file sharing plus a single
// empty `<sticker/>` element on the message.
//
// This file is the value and decision half and nothing else. It fetches nothing,
// decodes nothing, stores nothing, and imports nothing, so one set of rules can
// be applied from a send button, from a pack listing, and from a plain Dart
// test without dragging a database or an image codec into any of them. Every
// sticker it is asked about was published by a stranger.
//
// Three decisions in here are not obvious, and each is argued where it is made:
//
//   * A sticker is **content**, so it travels inside the encrypted payload.
//     That is the opposite of how this app treats a reaction, and the reason is
//     not "encryption is good". See stickerSendShape.
//   * A declared media type is evidence, not proof. See StickerSafety.check.
//   * A sticker with no integrity hash is not cacheable, and that has nothing
//     to do with whether it is safe to look at. See StickerItem.integrity.

/// Namespace of the `<sticker/>` marker element.
const kStickersNamespace = 'urn:xmpp:stickers:0';

/// The PEP node that holds sticker packs, and the node named in a pack URI.
const kStickerPubsubNode = 'urn:xmpp:stickers:0';

/// XEP-0447 stateless file sharing: carries the file and where to fetch it.
const kSfsNamespace = 'urn:xmpp:sfs:0';

/// XEP-0446 file metadata: media type, size, dimensions, hash.
const kFileMetadataNamespace = 'urn:xmpp:file:metadata:0';

/// XEP-0300 cryptographic hashes, version 2.
const kHashesNamespace = 'urn:xmpp:hashes:2';

/// XEP-0091 url-data: how a reader is told to fetch the bytes.
const kUrlDataNamespace = 'http://jabber.org/protocol/url-data';

/// What the sniffer reports for bytes it cannot identify.
///
/// The same value avatar.dart's sniffer returns in the same situation, so that a
/// caller holding both does not have to remember which spelling belongs to
/// which file.
const kUnknownMediaType = 'application/octet-stream';

/// Media types this app will decode and draw inline as a sticker.
///
/// A deliberately short list. An inline sticker is drawn at up to 512 px in the
/// middle of a conversation, which is the least forgiving place in the app to
/// meet a decoder, and the set of formats we are confident about there is small
/// enough to reason about. AVIF is absent because nothing here decodes it, not
/// because it is unsafe; GIF and APNG are absent because of `animated`.
const kDecodableStickerTypes = <String>{
  'image/png',
  'image/jpeg',
  'image/webp',
};

/// The largest sticker this app will attach to a message, in bytes.
///
/// The sticker metadata is not a reference to an upload we fetch later: the
/// `<sticker/>` marker and the `<file-sharing/>` element go inside the
/// encrypted payload, and that payload is base64 (4/3) inside an AEAD box which
/// is then base64'd again — about 1.8x the original on the wire. 256 KiB
/// therefore reaches the server as roughly 460 KiB, which is inside the stanza
/// limit the servers we actually talk to enforce. The pack examples in the XEP
/// are around 70 KiB for a 512x512 PNG.
const int kStickerSendMaxBytes = 256 * 1024;

/// The largest sticker this app will keep, in bytes.
///
/// One megabyte, deliberately not the send cap. A cache exists so that the last
/// few stickers are instant; a pack imported from someone else, or a sticker
/// chosen on another device, can legitimately be larger than anything we would
/// publish. Past this it is a download rather than a cache entry, and a cache
/// with no bound is how a phone runs out of room.
const int kStickerCacheMaxBytes = 1024 * 1024;

/// The longest edge we accept in a sticker's declared dimensions.
const int kStickerMaxDimension = 4096;

/// The widest aspect ratio we accept.
///
/// A decoder allocates width x height x 4 bytes before it reads a single pixel,
/// so a 1 x 400000 sticker is a 1.6 GB allocation triggered by a metadata claim
/// rather than by an image. Four is loose enough for the wide banner stickers
/// some packs ship, and tight enough that the worst case we admit —
/// 4096 x 1024 — is a 16 MiB surface, which a picture on a phone can afford.
const double kStickerMaxAspectRatio = 4.0;

/// The `<hash/>` of a sticker's bytes (XEP-0300), as published.
///
/// Not a security decision in the sense the name suggests: the value comes from
/// whoever published the pack, so it cannot authenticate anything. What it is
/// for is proving that the bytes still in hand are the bytes that were vetted
/// when the item was cached — which is also why the algorithm being SHA-1 is
/// not a problem, in the same way it is not a problem for an XEP-0084 avatar
/// item id.
class StickerIntegrity {
  const StickerIntegrity({required this.algorithm, required this.value});

  /// `sha-1` or `sha-256`, as in the `algo` attribute.
  final String algorithm;

  /// The hash, hex or base64 as the publisher wrote it.
  final String value;

  static const String sha1 = 'sha-1';

  static const String sha256 = 'sha-256';

  /// Whether this is a hash we can actually compare against.
  ///
  /// Shape, not strength: the algorithm must be one we know the output length of
  /// and the value must be that length in a recognised encoding. A hash we
  /// cannot compare is not a weak hash, it is no hash at all — which is why
  /// [StickerRefusal.malformedIntegrity] exists separately from
  /// [StickerRefusal.missingIntegrity] rather than both collapsing into "no
  /// hash": the second is a pack that said nothing, the first is a pack that
  /// said something we cannot use, and a caller may want to say so differently.
  ///
  /// Normalisation happens here rather than in the constructor so this stays a
  /// const value type: an algorithm spelled in capitals or a value with a
  /// trailing newline from a wrapped element is the same hash, and refusing it
  /// would be refusing a formatting quirk.
  bool get isWellFormed {
    final shape = _shapes[algorithm.trim().toLowerCase()];
    if (shape == null) return false;
    return shape.hasMatch(value.trim());
  }

  /// Hex and base64 in the two lengths XEP-0300 defines, plus base64url because
  /// some pack publishers emit it.
  ///
  /// Note what is *not* here: any hex length other than 40 or 64, and any
  /// truncated value. A pack item id is a truncated hash by the XEP's own
  /// construction, but a file hash is not, and accepting a short one would mean
  /// accepting something we cannot check a download against.
  // `final`, not `const`: RegExp has no const constructor, so a const map
  // literal cannot hold one. Nothing is lost — the patterns are built once, on
  // first use, and this map is only read by a validator.
  static final Map<String, RegExp> _shapes = <String, RegExp>{
    sha1: RegExp(
      r'^(?:[0-9a-fA-F]{40}|[A-Za-z0-9+/]{27}=|[A-Za-z0-9_-]{27}=)$',
    ),
    sha256: RegExp(
      r'^(?:[0-9a-fA-F]{64}|[A-Za-z0-9+/]{43}=|[A-Za-z0-9_-]{43}=)$',
    ),
  };
}

/// One sticker as a pack describes it.
///
/// None of these fields have been checked against anything. They are what a
/// stranger published, and the only field in this class that this file verifies
/// is [integrity] — and that only verifies the *hash*, never the sticker.
class StickerItem {
  const StickerItem({
    required this.id,
    this.name = '',
    this.description = '',
    this.mediaType = '',
    this.size = 0,
    this.width = 0,
    this.height = 0,
    this.integrity,
    this.sources = const <String>[],
    this.suggestions = const <String>[],
    this.packId = '',
  });

  /// Item id inside the pack. Opaque, chosen by the publisher.
  ///
  /// Nothing is derived from it: two packs may use the same id, so it is a key
  /// within a pack and not an identity.
  final String id;

  /// A human label, when the pack gives the sticker one.
  ///
  /// Not to be confused with [description]. A name is a label for a picker;
  /// [description] is the text shown *instead of* the picture.
  final String name;

  /// The `<desc/>`: the textual representation a recipient shows when they cannot
  /// draw the image, usually one emoji.
  ///
  /// Never empty for a sticker we send, and this is the one part of a sticker
  /// that is deliberately left in the clear when the rest is encrypted.
  final String description;

  /// The declared media type.
  ///
  /// Evidence. See [StickerSafety.check], which does not believe it.
  final String mediaType;

  /// The declared size in bytes, or 0 when the pack did not say.
  final int size;

  /// Declared width in pixels. Unverified; see the note on [StickerFormat].
  final int width;

  /// Declared height in pixels. Unverified; see the note on [StickerFormat].
  final int height;

  /// The hash of the file's bytes, if the pack published one.
  ///
  /// This is what makes a sticker cacheable. Without it a cache entry is a blob
  /// filed under a name a stranger chose: when the file is fetched again there
  /// is nothing to compare the new bytes against, so a source that quietly
  /// starts serving a different image is never noticed, and the sticker that
  /// passes every check today is a different sticker tomorrow with the same
  /// identity. Caching it would mean handing out a permanent exemption from the
  /// decoder checks in [StickerSafety.check], on the strength of metadata that nothing
  /// has ever confirmed.
  ///
  /// It also cannot be substituted by the pack item id. XEP-0449 derives that
  /// from a *truncated* hash of the whole pack, so it is a different thing that
  /// says nothing about this file.
  final StickerIntegrity? integrity;

  /// Where the bytes may be fetched from (XEP-0447 `<sources/>`).
  ///
  /// Every entry is untrusted input to an HTTP client, which is why
  /// [StickerRefusal.unusableSource] exists: a `file:` or `data:` URI in a pack
  /// from a stranger turns a picture into local file disclosure.
  final List<String> sources;

  /// `<suggest/>`: what the sender may substitute for the picture instead.
  final List<String> suggestions;

  /// Id of the pubsub item holding the pack, when there is one.
  ///
  /// Empty is normal and legal: XEP-0449 lets a sticker be sent with no pack at
  /// all, and this app supports that rather than inventing a pack to hold a
  /// sticker the user picked by hand.
  final String packId;
}

/// One sticker pack: where it lives, and what is in it.
class StickerPack {
  const StickerPack({
    required this.uri,
    required this.publisher,
    required this.node,
    required this.itemId,
    this.name = '',
    this.summary = '',
    this.restricted = false,
    this.items = const <StickerItem>[],
  });

  /// Builds a pack from a pack URI, or null when the URI is not one.
  ///
  /// A pack URI arrives from another client and ends up pasted into a send box,
  /// so the failure here is ordinary and is a null rather than an exception.
  static StickerPack? fromUri(
    String uri, {
    String name = '',
    String summary = '',
    bool restricted = false,
    List<StickerItem> items = const <StickerItem>[],
  }) {
    final location = parsePackUri(uri);
    if (location == null) return null;
    return StickerPack(
      uri: location.uri,
      publisher: location.publisher,
      node: location.node,
      itemId: location.itemId,
      name: name,
      summary: summary,
      restricted: restricted,
      items: items,
    );
  }

  /// The pack URI — the pack's identity, and what a peer sends to share it.
  final String uri;

  /// Bare JID of the node's owner.
  final String publisher;

  /// Pubsub node holding the pack.
  final String node;

  /// Pubsub item id of the pack.
  final String itemId;

  /// `<name/>`: the pack's display name.
  final String name;

  /// `<summary/>`: the pack's description, which XEP-0449 also expects to carry
  /// copyright and licence in a form a person can read.
  final String summary;

  /// `<restricted/>`: the publisher says this pack may not be imported.
  final bool restricted;

  final List<StickerItem> items;

  StickerItem? itemById(String id) {
    for (final item in items) {
      if (item.id == id) return item;
    }
    return null;
  }

  /// The pack's identity, recomposed from its parts rather than trusted from
  /// [uri].
  ///
  /// A hand-built pack can disagree with itself, and this is the reading of
  /// [uri] that the rest of the file would use.
  StickerPackUri? get location => parsePackUri(uri);
}

/// One pack's location: the node's owner, the node, and the item on it.
class StickerPackUri {
  const StickerPackUri({
    required this.publisher,
    required this.node,
    required this.itemId,
  });

  /// Bare JID of the node's owner.
  final String publisher;

  /// Pubsub node holding the pack.
  final String node;

  /// Pubsub item id of the pack.
  final String itemId;

  /// The URI, in the shape XEP-0449 §4.6 specifies: the XEP-0060 pubsub URI
  /// with `node=urn:xmpp:stickers:0`.
  ///
  /// The item id is percent-encoded, which is not decoration: the ids are
  /// base64, so a `+` left raw is read as a space by half the clients and a pack
  /// becomes unfetchable rather than merely unrecognised.
  String get uri =>
      'xmpp:$publisher?pubsub;action=retrieve;node=$node;item=${Uri.encodeComponent(itemId)}';

  @override
  String toString() => uri;

  /// Attributes for the `<sticker/>` marker that points at this pack.
  ///
  /// `jid` and `node` appear only when the pack is not on our own PEP node,
  /// which is the rule in XEP-0449 §4.4. Carrying them for a PEP pack as well
  /// would be harmless to a reader and wrong to every reader that has to decide
  /// whether to trust the sender about where their own pack lives.
  Map<String, String> markerAttributes() {
    if (node == kStickerPubsubNode) return <String, String>{'pack': itemId};
    return <String, String>{'pack': itemId, 'jid': publisher, 'node': node};
  }
}

/// Builds a pack URI, or null when the inputs could not name one.
///
/// Lenient in the same direction as [parsePackUri]: a URI we cannot build is
/// reported as absent rather than assembled from parts that do not make a pack.
String? buildPackUri({
  required String publisher,
  required String itemId,
  String node = kStickerPubsubNode,
}) {
  final bare = publisher.trim().split('/').first;
  if (!_looksLikePublisher(bare)) return null;
  final item = itemId.trim();
  if (!_isPackItemId(item)) return null;
  final cleanedNode = node.trim();
  if (cleanedNode.isEmpty || cleanedNode.length > 512) return null;
  return StickerPackUri(
    publisher: bare,
    node: cleanedNode,
    itemId: item,
  ).uri;
}

/// Parses a pack URI, or null when it is not one.
///
/// Everything here comes from another client. This function is on the paste path
/// of a send box, which is the last place a person should meet a crash, so every
/// malformation is a null and the whole body is inside one catch. There is no
/// version of a malformed pack URI that is worth an exception.
///
/// The older `urn:xmpp:sticker:0:<pack-id>@<publisher>` spelling is deliberately
/// neither produced nor accepted. The two forms disagree about where the
/// publisher sits, so accepting both would mean resolving the same string to two
/// different people's packs depending on which spelling a client preferred.
StickerPackUri? parsePackUri(String raw) {
  try {
    final text = raw.trim();
    if (text.length < 6 || text.length > 2048) return null;
    if (!_isPlainToken(text)) return null;
    if (text.substring(0, 5).toLowerCase() != 'xmpp:') return null;

    final rest = text.substring(5);
    final mark = rest.indexOf('?');
    final authority = mark < 0 ? rest : rest.substring(0, mark);
    final query = mark < 0 ? '' : rest.substring(mark + 1);

    final decodedAuthority = _percentDecode(authority);
    if (decodedAuthority == null) return null;
    // A resource is transport noise: the pack lives on the bare JID's node, and
    // keeping the resource would give one pack two URIs that do not compare
    // equal.
    final bare = decodedAuthority.split('/').first;
    if (!_looksLikePublisher(bare)) return null;

    var fields = query.split(';');
    if (fields.isEmpty) return null;
    var action = fields.first.toLowerCase();
    fields = fields.sublist(1);
    // `?query;pubsub;…` is the older XEP-0084 spelling of `?pubsub;…`. Both are
    // in the wild and the difference is not a distinction worth refusing a
    // packet over.
    if (action == 'query') {
      if (fields.isEmpty) return null;
      action = fields.first.toLowerCase();
      fields = fields.sublist(1);
    }
    if (action != 'pubsub') return null;

    String? rawNode;
    String? rawItem;
    String? rawAction;
    for (final part in fields) {
      final equals = part.indexOf('=');
      if (equals <= 0) continue;
      final key = part.substring(0, equals).toLowerCase();
      final value = part.substring(equals + 1);
      switch (key) {
        case 'action':
          rawAction = value;
        case 'node':
          rawNode = value;
        case 'item':
          rawItem = value;
        // Anything else belongs to a client newer than this file. Ignoring
        // unknown keys is how we stay compatible with one.
      }
    }
    // `action=retrieve` is the only action that names a pack to display. A
    // `create` or a `retract` on the same node is a different message about a
    // different thing, and reading it as "here is a pack" would import whatever
    // the sender last retracted.
    if (rawAction != null && rawAction.toLowerCase() != 'retrieve') return null;

    final node = rawNode == null ? null : _percentDecode(rawNode);
    final item = rawItem == null ? null : _percentDecode(rawItem);
    if (node == null || node.isEmpty || node.length > 512) return null;
    if (item == null || !_isPackItemId(item)) return null;

    return StickerPackUri(publisher: bare, node: node, itemId: item);
  } catch (_) {
    // Nothing that a hand-built or hostile string does here is worth an
    // exception reaching the send box.
    return null;
  }
}

bool _looksLikePublisher(String text) {
  if (text.isEmpty || text.length > 3071) return false;
  final at = text.indexOf('@');
  if (at < 0) {
    // A node hosted by a service rather than a personal one, e.g.
    // `xmpp:pubsub.shakespeare.lit?pubsub;…`. XEP-0060 allows it and it is not
    // this file's place to refuse a pack because its owner looks unusual.
    return text.contains('.');
  }
  if (at != text.lastIndexOf('@')) return false;
  return at > 0 && at + 1 < text.length;
}

bool _isPackItemId(String id) {
  // No length to check against: XEP-0449 derives the item id from a truncated
  // hash of the pack, so a length check would reject every conforming pack.
  // What is checkable is that it is one opaque token with nothing in it that
  // could make two different URIs name the same pack, or slip a newline into a
  // log line.
  if (id.length < 8 || id.length > 256) return false;
  return _isPlainToken(id);
}

/// False for a string containing a space, a C0 control or DEL.
///
/// Named for what it returns rather than for the test it performs, because it is
/// called in the negative at three sites and the inverted reading of the obvious
/// name is how one of them ends up rejecting every well-formed pack.
bool _isPlainToken(String text) {
  for (final unit in text.codeUnits) {
    if (unit <= 0x20 || unit == 0x7F) return false;
  }
  return true;
}

String? _percentDecode(String text) {
  try {
    return Uri.decodeComponent(text);
  } catch (_) {
    // A `%` that is not two hex digits. There is no other reading of the
    // string that means the same thing, so there is nothing to recover.
    return null;
  }
}

/// What a sticker's bytes actually are, as far as a header can tell.
class StickerFormat {
  const StickerFormat({required this.mediaType, required this.animated});

  /// The type the bytes are, or [kUnknownMediaType].
  ///
  /// This is the sniffed value and never the declared one. It is what goes into
  /// metadata we publish, because publishing the pack's claim about our own file
  /// would be publishing something we know to be untested.
  final String mediaType;

  /// Whether this format's file is animated.
  ///
  /// Decided from the container header, never by decoding. Dimensions are *not*
  /// read here: a header parser for four formats is a second concern with its
  /// own CVE surface, and until one exists the dimension checks below are
  /// judgements about a claim. That is stated at each of them rather than
  /// discovered later.
  final bool animated;
}

/// Identifies a sticker's bytes from their magic numbers.
///
/// The same move as `sniffMimeType` in avatar.dart, and the same reason: the
/// declared type is written by whoever published the pack, and believing it lets
/// a peer choose which decoder gets handed these bytes. It is written out here
/// rather than imported because avatar.dart reaches the storage layer through
/// its imports, and a send button should not need a database to know what a PNG
/// is — and because the answer this file needs is different by policy: a GIF is
/// reported as `image/gif` *and* animated, so the refusal can name the format
/// instead of saying we could not read it.
StickerFormat sniffStickerFormat(List<int> bytes) {
  if (_startsWith(bytes, const <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
    final animated = _pngIsAnimated(bytes);
    return StickerFormat(
      mediaType: animated ? 'image/apng' : 'image/png',
      animated: animated,
    );
  }
  if (_startsWith(bytes, const <int>[0xFF, 0xD8, 0xFF])) {
    return const StickerFormat(mediaType: 'image/jpeg', animated: false);
  }
  if (_startsWith(bytes, const <int>[0x47, 0x49, 0x46, 0x38])) {
    // Refused as animated whatever this particular file happens to hold. The
    // container can carry hundreds of frames, and the only way to be sure it
    // carries one is to walk the frame list, which is decoding.
    //
    // Which is also the reason to refuse it rather than inspect it: an animated
    // sticker is not a picture, it is something that happens to you, and it is
    // the one image feature whose cost the sender does not get to choose.
    return const StickerFormat(mediaType: 'image/gif', animated: true);
  }
  if (_isRiffWebp(bytes)) {
    return StickerFormat(
      mediaType: 'image/webp',
      animated: _webpIsAnimated(bytes),
    );
  }
  final brand = _isoBmffBrand(bytes);
  if (brand != null) {
    final avif = brand == 'avif' || brand == 'avis';
    return StickerFormat(
      mediaType: avif ? 'image/avif' : 'image/heic',
      // `avis` is the AVIF *sequence* brand, so it is the animated one.
      animated: brand == 'avis',
    );
  }
  return const StickerFormat(mediaType: kUnknownMediaType, animated: false);
}

bool _startsWith(List<int> bytes, List<int> magic) {
  if (bytes.length < magic.length) return false;
  for (var i = 0; i < magic.length; i++) {
    if (bytes[i] != magic[i]) return false;
  }
  return true;
}

bool _pngIsAnimated(List<int> bytes) {
  var offset = 8;
  while (offset + 8 <= bytes.length) {
    final length = _be32(bytes, offset);
    final type = String.fromCharCodes(bytes.sublist(offset + 4, offset + 8));
    // `acTL` before the first `IDAT` is what makes a PNG an APNG; after it, the
    // file is a still image with some extra frames a reader may ignore.
    if (type == 'acTL') return true;
    if (type == 'IDAT') return false;
    // A chunk length that does not fit the buffer ends the scan. A hostile
    // length must not walk us past the end of the file, and what we did read is
    // enough to call it a still image.
    if (offset + 12 + length > bytes.length) return false;
    offset += 12 + length;
  }
  return false;
}

bool _isRiffWebp(List<int> bytes) {
  if (bytes.length < 12) return false;
  if (!_startsWith(bytes, const <int>[0x52, 0x49, 0x46, 0x46])) return false;
  // 'WEBP' at offset 8, with the RIFF length field skipped: like every other
  // length here it is a claim, and reading past it is how a truncated file
  // becomes a crash.
  return bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50;
}

bool _webpIsAnimated(List<int> bytes) {
  // The animation flag lives in the `VP8X` header or in an `ANIM` chunk, both in
  // the first block of the file. A bounded window is enough to see either and
  // walking the whole RIFF looking for four bytes of literal would be decoding.
  final limit = bytes.length < 64 ? bytes.length : 64;
  for (var i = 12; i + 4 <= limit; i++) {
    if (bytes[i] == 0x41 &&
        bytes[i + 1] == 0x4E &&
        bytes[i + 2] == 0x49 &&
        bytes[i + 3] == 0x4D) {
      return true;
    }
  }
  return false;
}

String? _isoBmffBrand(List<int> bytes) {
  if (bytes.length < 12) return null;
  // 'ftyp' at offset 4. The box length in front of it is not read: it is a
  // claim, and every check in this file reads bytes at a fixed offset.
  if (bytes[4] != 0x66 ||
      bytes[5] != 0x74 ||
      bytes[6] != 0x79 ||
      bytes[7] != 0x70) {
    return null;
  }
  return String.fromCharCodes(bytes.sublist(8, 12));
}

int _be32(List<int> bytes, int offset) =>
    (bytes[offset] << 24) |
    (bytes[offset + 1] << 16) |
    (bytes[offset + 2] << 8) |
    bytes[offset + 3];

/// A sticker as something is about to use it: the published item, and the bytes
/// if they are in hand.
///
/// Bytes are absent in exactly one situation — an item read out of a pack we have
/// not fetched the file from — and the two paths are told apart rather than
/// guessed at, because a pack listing and an attachment are different decisions
/// and a caller that cannot tell which it has is a caller that will guess.
class StickerCandidate {
  const StickerCandidate({required this.item, this.bytes});

  final StickerItem item;

  /// The file's bytes, or null when only the metadata has been read.
  final List<int>? bytes;
}

/// Why a sticker may not be used.
///
/// The three `blocks*` predicates below divide these into the questions they
/// answer, and the division is the substance of this file: "we will not attach
/// this to a message" is not "this is unsafe to look at" is not "this is not
/// worth keeping". A sticker can be any one of the three without being the
/// other two, and a client that checks only one of them is either sending things
/// it should not, or refusing to show a picture the other person actually sent.
enum StickerRefusal {
  /// The bytes are not a format this app decodes, or could not be identified at
  /// all.
  ///
  /// Blocks sending and displaying.
  undecodableMediaType,

  /// The declared media type and the magic bytes are different formats.
  ///
  /// Blocks sending and displaying.
  declaredTypeMismatch,

  /// The file can animate.
  ///
  /// Blocks sending and displaying, and the reason is not the decoder: XEP-0449
  /// §5 notes that flickering stickers can induce seizures, and an animation is
  /// also the one image feature whose cost a sender does not have to pay — they
  /// choose when to look at it and the recipient does not. A still JPEG in a
  /// weird aspect ratio is merely ugly.
  animated,

  /// A dimension is missing, zero or negative.
  ///
  /// Blocks sending and displaying: an inline sticker reserves its box from these
  /// numbers, so zero is a division by nowhere and it is not the sender's
  /// business what we would draw instead.
  unknownDimensions,

  /// A dimension or an aspect ratio beyond what any decoder should be asked for.
  ///
  /// Blocks sending and displaying. This is the weakest check in the file and
  /// the only one with a hole in it: nothing here compares these numbers to the
  /// bytes, so a peer that declares 512x512 and ships a 40000x40000 PNG passes
  /// here. Closing that needs a header read, which is decoding, which is not this
  /// file. It stays because refusing a plausible claim costs nothing and the
  /// claim is the only lever available.
  absurdDimensions,

  /// Larger than [kStickerSendMaxBytes] or [kStickerCacheMaxBytes].
  ///
  /// Blocks sending and caching, not displaying. The cap is a budget for what we
  /// are willing to put in a stanza and on disk, and a sticker that already
  /// arrived has already been paid for: refusing to *show* a picture somebody
  /// chose for us because it is 300 KiB would be this client rewriting their
  /// message on a technicality. The fallback text still stands in for it.
  tooLarge,

  /// The declared size is not the number of bytes in hand.
  ///
  /// Blocks sending and caching. The declared size is what a reader's fetcher
  /// budgets against, so a pack that says 2 KiB and ships 40 MB is not a pack
  /// with a typo — it is a peer who has found the one number we would otherwise
  /// have stopped reading at. Publishing it would be worse: we would be putting
  /// that lie into a pack ourselves.
  declaredSizeDisagrees,

  /// Not square.
  ///
  /// Blocks sending only. Stickers are drawn in a fixed box, so a conforming
  /// client will letterbox a 3:2 sticker however we label it — and the right
  /// outcome for a picture the user chose that is not square is for this file to
  /// refuse the sticker affordance, leaving them to send it as the photo it is.
  notSquare,

  /// No `<desc/>`, so there is no text to show in place of the picture.
  ///
  /// Blocks sending only. An empty description is an empty bubble on every
  /// client that cannot draw the sticker, including the one that asked for it.
  noFallbackText,

  /// No bytes: this is an item read from a pack listing, not a file.
  ///
  /// Blocks sending and displaying, not caching. Sending means attaching a file,
  /// so with no file there is nothing to send and a download link is a different
  /// feature. Caching the metadata is exactly what a listing is for — it is how
  /// a picker shows sixty names without fetching sixty files.
  bytesUnavailable,

  /// A `<sources/>` entry that is not an http(s) URL.
  ///
  /// Blocks sending and displaying. The URI is untrusted input to an HTTP
  /// client; `file:` and `data:` arrive in packs from strangers and turn a
  /// picture into local file disclosure or an inline payload, and a URI with
  /// whitespace in it is a header to whatever HTTP client we hand it to.
  unusableSource,

  /// No hash published.
  ///
  /// Blocks caching only. See [StickerItem.integrity] for why a sticker without
  /// one cannot be cached, and why that has nothing to do with sending it.
  missingIntegrity,

  /// A hash we cannot compare against, or an algorithm we do not know.
  ///
  /// Blocks caching only, and is kept apart from [missingIntegrity] because a
  /// pack that said nothing and a pack that said something unusable are
  /// different conversations to have with its publisher.
  malformedIntegrity;

  /// True when this stops us attaching the sticker to a message.
  ///
  /// Everything except the caching rules: a sticker we may not keep is still one
  /// we can send, and conflating the two would make a pack with a malformed
  /// hash unsendable, which is not what is wrong with it.
  bool get blocksSend => switch (this) {
        StickerRefusal.missingIntegrity ||
        StickerRefusal.malformedIntegrity =>
          false,
        _ => true,
      };

  /// True when this stops us handing the bytes to a decoder and drawing them in
  /// a bubble.
  ///
  /// The absences are all about *our own* published metadata or our own budgets:
  /// the size cap, a size that disagrees, a shape that is not square, a missing
  /// fallback, and the two hash rules. None of those make a picture dangerous to
  /// look at, and the person who sent it would not understand the refusal.
  bool get blocksDisplay => switch (this) {
        StickerRefusal.tooLarge ||
        StickerRefusal.declaredSizeDisagrees ||
        StickerRefusal.notSquare ||
        StickerRefusal.noFallbackText ||
        StickerRefusal.missingIntegrity ||
        StickerRefusal.malformedIntegrity =>
          false,
        _ => true,
      };

  /// True when this stops us keeping the sticker.
  ///
  /// A pack item with no usable hash is not worth a cache entry at all: there
  /// would be nothing to check a later fetch against. An over-cap item is worth
  /// downloading and not worth keeping.
  ///
  /// [StickerRefusal.declaredSizeDisagrees] blocks caching even though it does
  /// not block display, and the asymmetry is the point. A picture with a wrong
  /// caption is still the picture the sender chose, so refusing to draw it would
  /// be this client rewriting their message over metadata. But the declared size
  /// is the number a reader budgets against *before* reading the bytes — it is
  /// the guard, not a label — so caching under a size already caught lying lets a
  /// 40 MB file enter the cache wearing a 2 KB declaration, which is precisely
  /// what the guard was for.
  bool get blocksCaching => switch (this) {
        StickerRefusal.tooLarge ||
        StickerRefusal.missingIntegrity ||
        StickerRefusal.malformedIntegrity ||
        StickerRefusal.declaredSizeDisagrees =>
          true,
        _ => false,
      };
}

/// One sentence per refusal, in the register the rest of the app uses: the
/// subject is what happens, not what we think of it.
///
/// Separate from the enum so the phrasing can be read on its own, and so a
/// caller can show a reason without every value having to carry one.
extension StickerRefusalMessage on StickerRefusal {
  String get reason => switch (this) {
        StickerRefusal.undecodableMediaType =>
          'This sticker is not in a format we can display.',
        StickerRefusal.declaredTypeMismatch =>
          'This sticker says it is one format and is another.',
        StickerRefusal.animated =>
          'This sticker is an animation, which is not shown in a conversation.',
        StickerRefusal.unknownDimensions =>
          'This sticker does not say how big it is.',
        StickerRefusal.absurdDimensions =>
          'This sticker is too large an image to be drawn safely.',
        StickerRefusal.tooLarge =>
          'This sticker is too large to send or to keep.',
        StickerRefusal.declaredSizeDisagrees =>
          'This sticker does not match the size it advertises.',
        StickerRefusal.notSquare =>
          'Stickers are square; send this as a photo.',
        StickerRefusal.noFallbackText =>
          'This sticker has no text to show when the picture cannot be drawn.',
        StickerRefusal.bytesUnavailable =>
          'This sticker has not been downloaded yet.',
        StickerRefusal.unusableSource =>
          'This sticker cannot be fetched from where it says.',
        StickerRefusal.missingIntegrity =>
          'This sticker has no checksum, so it cannot be kept.',
        StickerRefusal.malformedIntegrity =>
          'This sticker has a checksum we cannot check, so it cannot be kept.',
      };
}

/// What may be done with one sticker.
///
/// Three answers rather than one, because the three questions are different and
/// a single boolean would force the strictest answer onto all three. A 300 KiB
/// sticker is refused for sending and shown anyway; a sticker from a pack with no
/// hashes is sent, shown, and not cached.
class StickerVerdict {
  StickerVerdict(Iterable<StickerRefusal> refusals)
      : refusals = List<StickerRefusal>.unmodifiable(refusals);

  /// Every refusal that applies, in the order they were found.
  ///
  /// Not just the first one: a caller reporting to a person reports the most
  /// alarming, and a peer being told only about the animation we found first
  /// would not learn that its metadata lies about the type.
  final List<StickerRefusal> refusals;

  bool get canSend => !refusals.any((r) => r.blocksSend);

  bool get canDisplay => !refusals.any((r) => r.blocksDisplay);

  bool get canCache => !refusals.any((r) => r.blocksCaching);

  /// The first refusal that stops a send, for wording a single reason.
  StickerRefusal? get blockedSend {
    for (final refusal in refusals) {
      if (refusal.blocksSend) return refusal;
    }
    return null;
  }

  /// The first refusal that stops a display, for wording a single reason.
  StickerRefusal? get blockedDisplay {
    for (final refusal in refusals) {
      if (refusal.blocksDisplay) return refusal;
    }
    return null;
  }

  @override
  String toString() => 'StickerVerdict($refusals)';
}

/// Applies every rule in this file to one sticker.
///
/// The bytes decide what the sticker is; the item is only a claim about it.
///
/// A declared media type is evidence, not proof. The type comes from whoever
/// published the pack. The bytes are what our decoder actually receives, and the
/// two can disagree — so the bytes decide. Trusting the declaration instead is
/// how a peer chooses which decoder gets handed these bytes, and no amount of
/// validation after the fact repairs that: the hand-off has already happened.
/// See `sniffMimeType` in avatar.dart for the same rule applied to avatars.
class StickerSafety {
  const StickerSafety._();

  /// Every refusal that applies to [candidate], in the order they were found.
  ///
  /// One pass, one answer, three questions asked of it — see [StickerVerdict]
  /// for why the callers below do not each call their own check. A validator that
  /// let a caller pick which rules to run would eventually have two callers
  /// picking different ones.
  static StickerVerdict check(StickerCandidate candidate) {
    final item = candidate.item;
    final bytes = candidate.bytes;
    final refusals = <StickerRefusal>[];

    final integrity = item.integrity;
    if (integrity == null) {
      refusals.add(StickerRefusal.missingIntegrity);
    } else if (!integrity.isWellFormed) {
      refusals.add(StickerRefusal.malformedIntegrity);
    }

    if (item.size > kStickerSendMaxBytes) refusals.add(StickerRefusal.tooLarge);
    if (item.description.trim().isEmpty) {
      refusals.add(StickerRefusal.noFallbackText);
    }

    if (item.width <= 0 || item.height <= 0) {
      refusals.add(StickerRefusal.unknownDimensions);
    } else {
      final longest = item.width > item.height ? item.width : item.height;
      final shortest = item.width > item.height ? item.height : item.width;
      if (longest > kStickerMaxDimension ||
          longest / shortest > kStickerMaxAspectRatio) {
        refusals.add(StickerRefusal.absurdDimensions);
      } else if (item.width != item.height) {
        refusals.add(StickerRefusal.notSquare);
      }
    }

    var usableSources = item.sources.isNotEmpty;
    for (final source in item.sources) {
      if (!_isFetchable(source)) {
        usableSources = false;
        break;
      }
    }
    if (!usableSources) refusals.add(StickerRefusal.unusableSource);

    if (bytes == null) {
      refusals.add(StickerRefusal.bytesUnavailable);
    } else {
      // A size of zero means the pack never said, which is not a disagreement.
      // Anything else that is not the byte count is.
      if (item.size != 0 && item.size != bytes.length) {
        refusals.add(StickerRefusal.declaredSizeDisagrees);
      }

      final format = sniffStickerFormat(bytes);
      final declared = _normaliseMediaType(item.mediaType);
      // No mismatch is reported against bytes we could not identify. "We could
      // not read it" is the honest statement; a mismatch verdict would assert a
      // knowledge we do not have, and would be quoted back at whoever sent it.
      if (format.mediaType != kUnknownMediaType &&
          declared != null &&
          declared != _normaliseMediaType(format.mediaType)) {
        refusals.add(StickerRefusal.declaredTypeMismatch);
      }
      if (format.animated) {
        refusals.add(StickerRefusal.animated);
      } else if (!kDecodableStickerTypes.contains(format.mediaType)) {
        refusals.add(StickerRefusal.undecodableMediaType);
      }
    }

    return StickerVerdict(refusals);
  }
}

/// Whether this sticker may be attached to a message.
///
/// The counterpart of the verdict for display, and deliberately not the same
/// answer: a sticker can fail one and pass the other, and the reasons it fails
/// to send are mostly about what *we* would be publishing rather than about the
/// picture.
///
/// When this is false the sticker is not sent at all. It is not sent as a
/// message, and it is not sent with the metadata left off. Track_resolver.dart's
/// rule — the client picks the track and the program never silently substitutes
/// one — is not weakened by refusing here, because a sticker this file will not
/// send is refused before a track is resolved, so no track is ever chosen for it.
bool isSafeToSend(StickerCandidate candidate) =>
    StickerSafety.check(candidate).canSend;

/// Whether this sticker's bytes may be decoded and drawn inline.
///
/// Weaker than [isSafeToSend] on purpose, and the difference is the whole point
/// of the two: the checks that stop a send are mostly our own publishing
/// standards and our own stanza budget, and refusing to show a picture somebody
/// sent us on those grounds would be this client rewriting their message.
bool isSafeToDisplay(StickerCandidate candidate) =>
    StickerSafety.check(candidate).canDisplay;

/// Whether this item may be kept.
///
/// Not a third opinion on the first two: an item with no usable hash can be sent
/// and shown and still must not be cached, because nothing would ever check the
/// bytes again. See [StickerItem.integrity].
bool isCacheable(StickerCandidate candidate) =>
    StickerSafety.check(candidate).canCache;

/// Whether a source URI may be handed to a fetcher.
///
/// http is allowed, not just https, and the reason is the hash rather than
/// leniency: the pack's size is checked against what arrives and the pack's hash
/// is checked against the bytes, so a network that substitutes something is
/// caught by both. Refusing plain http would instead leave the recipient with the
/// fallback text, which is a worse outcome for a smaller threat.
bool _isFetchable(String uri) {
  final text = uri.trim();
  // A source URI is pasted straight into an HTTP client. An unbounded one from a
  // pack is a way to make that client do work nobody asked for.
  if (text.isEmpty || text.length > 2048) return false;
  if (!_isPlainToken(text)) return false;
  final lower = text.toLowerCase();
  return lower.startsWith('https://') || lower.startsWith('http://');
}

String? _normaliseMediaType(String raw) {
  final text = raw.trim().toLowerCase();
  if (text.isEmpty) return null;
  // Parameters are transport detail. A peer that wrote `image/png; charset=x`
  // has not contradicted us, and refusing it would drop an honest sticker.
  final semicolon = text.indexOf(';');
  final base =
      semicolon < 0 ? text : text.substring(0, semicolon).trim();
  return _mediaTypeSpellings[base] ?? base;
}

/// Spellings, not formats.
///
/// `image/jpg` is what a good many pack publishers write. The mismatch rule
/// exists to catch a peer pointing our decoder at bytes it was not written for,
/// not to police how somebody spells a filename's extension.
const Map<String, String> _mediaTypeSpellings = <String, String>{
  'image/jpg': 'image/jpeg',
  'image/pjpeg': 'image/jpeg',
  'image/x-png': 'image/png',
};

/// One node of a stanza, as data.
///
/// Not raw XML and not an moxxmpp extension. The caller assembling the message
/// already owns that, and a send path that cannot be used without a database, an
/// image codec and a stanza builder cannot be unit tested at all.
class StickerStanzaNode {
  const StickerStanzaNode(
    this.tag, {
    this.xmlns,
    this.attributes = const <String, String>{},
    this.text,
    this.children = const <StickerStanzaNode>[],
  });

  final String tag;
  final String? xmlns;
  final Map<String, String> attributes;
  final String? text;
  final List<StickerStanzaNode> children;

  /// The first child with this tag, for a caller walking the shape.
  StickerStanzaNode? child(String tag) {
    for (final node in children) {
      if (node.tag == tag) return node;
    }
    return null;
  }

  /// Depth-first search for the first node with this tag anywhere below.
  StickerStanzaNode? descendant(String tag) {
    for (final node in children) {
      if (node.tag == tag) return node;
      final found = node.descendant(tag);
      if (found != null) return found;
    }
    return null;
  }
}

/// Everything one sticker send needs, and the decision about where it goes.
class StickerSendShape {
  StickerSendShape._({
    required this.marker,
    required this.fileSharing,
    required this.cleartextBody,
  });

  /// `<sticker xmlns='urn:xmpp:stickers:0' …/>`.
  final StickerStanzaNode marker;

  /// `<file-sharing xmlns='urn:xmpp:sfs:0'>…</file-sharing>`.
  final StickerStanzaNode fileSharing;

  /// The `<desc/>`: the one part of a sticker that leaves in the clear.
  final String cleartextBody;

  /// The nodes to place in the plaintext that the chosen track encrypts.
  List<StickerStanzaNode> get encryptedPayloadNodes =>
      <StickerStanzaNode>[marker, fileSharing];

  /// The nodes that may be placed outside the encrypted payload.
  ///
  /// Empty, and always empty. It exists so that the absence is a thing a caller
  /// can see and a test can assert, rather than a rule in a comment that a
  /// caller has to remember. There is no plaintext sticker send to reach for:
  /// getting the metadata out of the ciphertext is not a mode of this API, it is
  /// a different program.
  List<StickerStanzaNode> get publicNodes => const <StickerStanzaNode>[];
}

/// Builds the shape one sticker send needs, or null when there is nothing to
/// send.
///
/// Null means "do not send this as a sticker", and never "send it some other
/// way": a sticker refused here is refused as a sticker, and a caller that
/// wants a picture sent anyway should offer the photo affordance, which is a
/// decision for the user to take rather than one this file makes for them.
///
/// A sticker is **content**. There is no message underneath the image that it is
/// a decoration of, so the `<file-sharing/>` metadata says as much about the
/// conversation as the body would, and both it and the marker go inside the
/// encrypted payload. This is the opposite of how this app sends a reaction
/// (XEP-0444, unencrypted) and the reasoning does not transfer:
///
///   A reaction is metadata *about* a message. It is meaningless to anyone who
///   cannot read the message it points at, and it is pointed at by origin-id so
///   that it survives archiving — the whole design assumes the recipient sees the
///   message. Sending it in the clear is what makes it appear on the sender's
///   other devices and in Conversations and Signal; wrapped in OMEMO it would be
///   invisible to every client that is not us, and a reaction the other person
///   cannot see is not a reaction.
///
///   A sticker has no such fallback. Put its metadata in the clear and the
///   server, and anyone who can read what the server logged, learns exactly
///   which picture was sent — more than the fallback emoji reveals, since the
///   emoji is the sender's own choice and the file is not. A client that cannot
///   decrypt the payload could not have drawn the sticker anyway, so the clear
///   copy buys that client nothing and costs the sender the file it was sending.
///
/// Hence the split this type makes explicit: [encryptedPayloadNodes] goes into
/// the plaintext the track encrypts, and [cleartextBody] — the `<desc/>`, which
/// the sender chose as the fallback — is the only part that goes out in the
/// clear, because it is what the recipient would see in any case if they could
/// not decrypt.
StickerSendShape? stickerSendShape({
  required StickerCandidate candidate,
  StickerPackUri? pack,
  List<String>? sourceUris,
}) {
  final verdict = StickerSafety.check(candidate);
  if (!verdict.canSend) return null;

  final item = candidate.item;
  // `canSend` implies this: bytesUnavailable blocks sending.
  final bytes = candidate.bytes!;

  // Sources the caller just uploaded to. They have not been through the item's
  // own check, so they are checked here rather than assumed: an upload that
  // produced no usable URL has produced no sticker.
  final sources = sourceUris ?? item.sources;
  if (sources.isEmpty) return null;
  for (final source in sources) {
    if (!_isFetchable(source)) return null;
  }

  final integrity = item.integrity;
  if (integrity == null || !integrity.isWellFormed) {
    // A verdict is not a shape. XEP-0449 lets a sender omit the hash and a
    // reader can still fetch the file, but this client's reader uses the hash as
    // its cache key, so a sticker we sent without one could not be re-fetched and
    // re-checked later. We would be the first client unable to use what we sent.
    return null;
  }

  // The type and size published here are measured, not copied from the pack.
  // For an outgoing sticker the bytes are ours, so the pack's claims about them
  // are either absent or wrong, and repeating them would put a claim this client
  // has already disproved into a pack other people will fetch.
  final format = sniffStickerFormat(bytes);

  final marker = StickerStanzaNode(
    'sticker',
    xmlns: kStickersNamespace,
    attributes: pack?.markerAttributes() ?? const <String, String>{},
  );

  final file = StickerStanzaNode(
    'file',
    xmlns: kFileMetadataNamespace,
    children: <StickerStanzaNode>[
      StickerStanzaNode('media-type', text: format.mediaType),
      StickerStanzaNode('desc', text: item.description),
      StickerStanzaNode('size', text: '${bytes.length}'),
      StickerStanzaNode('dimensions', text: '${item.width}x${item.height}'),
      StickerStanzaNode(
        'hash',
        xmlns: kHashesNamespace,
        attributes: <String, String>{'algo': integrity.algorithm},
        text: integrity.value,
      ),
    ],
  );

  final fileSharing = StickerStanzaNode(
    'file-sharing',
    xmlns: kSfsNamespace,
    children: <StickerStanzaNode>[
      file,
      StickerStanzaNode(
        'sources',
        children: <StickerStanzaNode>[
          for (final source in sources)
            StickerStanzaNode(
              'url-data',
              xmlns: kUrlDataNamespace,
              attributes: <String, String>{'target': source},
            ),
        ],
      ),
    ],
  );

  return StickerSendShape._(
    marker: marker,
    fileSharing: fileSharing,
    cleartextBody: item.description,
  );
}