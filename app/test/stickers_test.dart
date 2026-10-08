// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Stickers (XEP-0449, `urn:xmpp:stickers:0`).
//
// The register here is the same as avatar_test.dart's and for the same reason:
// **every sticker in this file was published by a stranger**. So each group asks
// one question — what is the worst sticker this function could be handed? — and
// the fixture for a normal sticker is built to be unremarkable on purpose, so
// that a test that passes for the wrong reason is visible.
//
// Three things are worth pointing at, because they are the parts a reviewer is
// most likely to get wrong:
//
//   * The declared media type is never believed. `declaredTypeMismatch` and its
//     inverse (a declared `image/png` with PNG bytes, accepted) are the same
//     test seen from two sides, and both are here because a validator that only
//     tests one of them has tested the easy direction.
//   * "Safe to send" and "safe to display" are different questions, and the size
//     cap is where they come apart. The tests name which verdict they expect and
//     why, rather than asserting a boolean.
//   * There is no cleartext send. `publicNodes` being empty is an assertion, not
//     a comment: it is the one thing in the API that makes the encrypted/clear
//     split impossible to get wrong by reaching for the wrong getter.

import 'package:test/test.dart';
import 'package:resonchat/xmpp/stickers.dart';

/// The XEP's own example file hash, which is also a well-formed sha-256 value.
const _sha256 = StickerIntegrity(
  algorithm: 'sha-256',
  value: 'gw+6xdCgOcvCYSKuQNrXH33lV9NMzuDf/s0huByCDsY=',
);

/// SHA-1 of the word "hello", as an XEP-0084 avatar item id would be.
const _sha1 = StickerIntegrity(
  algorithm: 'sha-1',
  value: 'aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d',
);

/// The pack item id from XEP-0449 §4.6. Note it is a *truncated* hash, and the
/// parser must not have a length rule for it.
const _packItemId = 'EpRv28DHHzFrE4zd+xaNpVb4';

/// The pack URI from XEP-0449 §4.6, verbatim.
const _xepPackUri =
    'xmpp:romeo@montague.lit?pubsub;action=retrieve;'
    'node=urn:xmpp:stickers:0;item=EpRv28DHHzFrE4zd%2BxaNpVb4';

StickerItem _item({
  String id = 'sticker-1',
  String mediaType = 'image/png',
  int? size,
  int width = 512,
  int height = 512,
  StickerIntegrity? integrity = _sha256,
  String description = '😘',
  List<String> sources = const ['https://cdn.example/marsey.png'],
}) {
  return StickerItem(
    id: id,
    description: description,
    mediaType: mediaType,
    size: size ?? 0,
    width: width,
    height: height,
    integrity: integrity,
    sources: sources,
  );
}

/// A candidate whose declared size is the real byte count, which is what an
/// honest pack looks like. Every hostile test overrides the field it is about.
StickerCandidate _candidate(List<int> bytes, {StickerItem? item}) {
  return StickerCandidate(
    item: item ?? _item(size: bytes.length),
    bytes: bytes,
  );
}

String _repeat(String unit, int times) =>
    List<String>.filled(times, unit).join();

List<int> _chunk(String type, List<int> data) {
  return <int>[
    (data.length >> 24) & 0xFF,
    (data.length >> 16) & 0xFF,
    (data.length >> 8) & 0xFF,
    data.length & 0xFF,
    ...type.codeUnits,
    ...data,
    // The CRC. Nothing in the sniffer reads it and no real reader either — this
    // file does not decode, and a fixture that carried a correct one would only
    // make the tests slower.
    0, 0, 0, 0,
  ];
}

List<int> _png({bool animated = false, int fill = 0}) {
  final bytes = <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  if (animated) {
    bytes.addAll(_chunk('acTL', <int>[0, 0, 0, 1, 0, 0, 0, 1]));
  }
  bytes.addAll(_chunk('IHDR', List<int>.filled(13, 0)));
  bytes.addAll(_chunk('IDAT', <int>[0x78, 0x9C]));
  bytes.addAll(_chunk('IEND', List<int>.filled(fill, 0)));
  return bytes;
}

List<int> _jpeg() => <int>[
  0xFF,
  0xD8,
  0xFF,
  0xE0,
  0x00,
  0x10,
  0x4A,
  0x46,
  0x49,
  0x46,
  0,
  0,
];

List<int> _gif() => <int>[
  0x47,
  0x49,
  0x46,
  0x38,
  0x39,
  0x61,
  0x01,
  0x00,
  0x01,
  0x00,
];

List<int> _webp({bool animated = false}) {
  final bytes = <int>[
    0x52, 0x49, 0x46, 0x46, 0x1A, 0x00, 0x00, 0x00, //
    0x57, 0x45, 0x42, 0x50, //
    0x56, 0x50, 0x38, 0x58, // 'VP8X'
  ];
  if (animated) bytes.addAll(<int>[0x41, 0x4E, 0x49, 0x4D]); // 'ANIM'
  bytes.addAll(<int>[0x00, 0x00, 0x00, 0x00]);
  return bytes;
}

List<int> _avif({bool sequence = false}) {
  return <int>[
    0x00, 0x00, 0x00, 0x20, //
    0x66, 0x74, 0x79, 0x70, // 'ftyp'
    ...(sequence ? 'avis' : 'avif').codeUnits,
    ...List<int>.filled(8, 0),
  ];
}

void main() {
  group('a pack URI', () {
    test('is the XEP example verbatim', () {
      // The one fixture that proves the parser is a parser and not a guess: this
      // is the URI in XEP-0449 §4.6, including the escaped `+`.
      final parsed = parsePackUri(_xepPackUri);
      expect(parsed, isNotNull);
      expect(parsed!.publisher, 'romeo@montague.lit');
      expect(parsed.node, 'urn:xmpp:stickers:0');
      expect(parsed.itemId, _packItemId);
      expect(parsed.uri, _xepPackUri);
    });

    test('round-trips through the builder', () {
      final built = buildPackUri(
        publisher: 'romeo@montague.lit',
        itemId: _packItemId,
      );
      expect(built, _xepPackUri);
      expect(parsePackUri(built!)!.itemId, _packItemId);
    });

    test('malformed input is null, and nothing throws', () {
      // The worst case is a send box: these strings arrive from another client
      // and get pasted by a person. None of them may become an exception.
      final hostile = <String>[
        '',
        'x',
        'xmpp:',
        'not a uri at all',
        'https://cdn.example/pack.png',
        'urn:xmpp:stickers:0',
        // The older draft spelling: refused on purpose, because it puts the
        // publisher somewhere the real form does not.
        'urn:xmpp:sticker:0:$_packItemId@montague.lit',
        // No pubsub action.
        'xmpp:romeo@montague.lit',
        'xmpp:romeo@montague.lit?message;body=hi',
        // Empty and doubled localparts.
        'xmpp:@montague.lit?pubsub;action=retrieve;node=urn:xmpp:stickers:0;item=$_packItemId',
        'xmpp:romeo@@montague.lit?pubsub;action=retrieve;node=urn:xmpp:stickers:0;item=$_packItemId',
        // A different action on the same node: a create or a retract says
        // something else about the node entirely.
        'xmpp:romeo@montague.lit?pubsub;action=create;node=urn:xmpp:stickers:0;item=$_packItemId',
        // Missing half the identity.
        'xmpp:romeo@montague.lit?pubsub;action=retrieve;node=urn:xmpp:stickers:0',
        'xmpp:romeo@montague.lit?pubsub;action=retrieve;item=$_packItemId',
        // A `%` that is not an escape. Nothing here decodes, and nothing may
        // throw either.
        'xmpp:romeo@montague.lit?pubsub;action=retrieve;node=urn:xmpp:stickers:0;item=%ZZ',
        // An item id long enough to be an attempt at something.
        'xmpp:romeo@montague.lit?pubsub;action=retrieve;node=urn:xmpp:stickers:0;item=${_repeat('A', 4000)}',
        // A newline, which is also how a log line gets forged.
        'xmpp:romeo@montague.lit?pubsub;action=retrieve;node=urn:xmpp:stickers:0\n;item=$_packItemId',
        List<String>.filled(400, 'x').join(),
      ];
      for (final raw in hostile) {
        expect(() => parsePackUri(raw), returnsNormally, reason: raw);
        expect(parsePackUri(raw), isNull, reason: raw);
      }
    });

    test('tolerates whitespace around a pasted URI', () {
      // The stated reason this parser is lenient at all: the string arrives in a
      // send box, and the space after it is the user's typing, not an attack.
      expect(parsePackUri('  $_xepPackUri \n')!.itemId, _packItemId);
    });

    test('drops a resource so one pack has one URI', () {
      // The pack lives on the bare JID's node, so keeping the resource would
      // give the same pack two URIs that do not compare equal.
      final parsed = parsePackUri(
        'xmpp:romeo@montague.lit/pda?pubsub;action=retrieve;'
        'node=urn:xmpp:stickers:0;item=$_packItemId',
      );
      expect(parsed!.publisher, 'romeo@montague.lit');
      expect(parsed.uri, _xepPackUri);
    });

    test('accepts the older query spelling', () {
      // `?query;pubsub;…` is XEP-0084's form and is in the wild. Refusing it
      // would refuse a real pack over a semicolon.
      final parsed = parsePackUri(
        'xmpp:romeo@montague.lit?query;pubsub;action=retrieve;'
        'node=urn:xmpp:stickers:0;item=$_packItemId',
      );
      expect(parsed!.itemId, _packItemId);
    });

    test('ignores keys from a client newer than this one', () {
      final parsed = parsePackUri(
        'xmpp:romeo@montague.lit?pubsub;action=retrieve;max-age=60;'
        'node=urn:xmpp:stickers:0;item=$_packItemId;something-new=1',
      );
      expect(parsed!.publisher, 'romeo@montague.lit');
      expect(parsed.itemId, _packItemId);
    });

    test('accepts a pack on a service node, not just a PEP one', () {
      // XEP-0060 allows a pack on a general pubsub service, and refusing one
      // because its owner looks unusual is not this file's business.
      final parsed = parsePackUri(
        'xmpp:pubsub.shakespeare.lit?pubsub;action=retrieve;'
        'node=stickers;item=$_packItemId',
      );
      expect(parsed!.publisher, 'pubsub.shakespeare.lit');
      expect(parsed.node, 'stickers');
    });

    test('the builder refuses what it cannot name', () {
      expect(buildPackUri(publisher: '', itemId: _packItemId), isNull);
      expect(buildPackUri(publisher: 'romeo@', itemId: _packItemId), isNull);
      expect(buildPackUri(publisher: 'nonsense', itemId: _packItemId), isNull);
      expect(buildPackUri(publisher: 'romeo@montague.lit', itemId: ''), isNull);
      // Long enough to pass a length rule, so what refuses it is the space: one
      // item id, not two readings of it.
      expect(
        buildPackUri(
          publisher: 'romeo@montague.lit',
          itemId: 'aaaaaaaaa aaaaaaaaa',
        ),
        isNull,
      );
      expect(
        buildPackUri(
          publisher: 'romeo@montague.lit',
          itemId: _packItemId,
          node: '  ',
        ),
        isNull,
      );
    });

    test('a pack remembers where it came from', () {
      final pack = StickerPack.fromUri(
        _xepPackUri,
        name: 'Marsey the Cat',
        items: <StickerItem>[_item()],
      );
      expect(pack, isNotNull);
      expect(pack!.publisher, 'romeo@montague.lit');
      expect(pack.location!.itemId, _packItemId);
      expect(pack.itemById('sticker-1'), isNotNull);
      expect(pack.itemById('nope'), isNull);
      expect(StickerPack.fromUri('nonsense'), isNull);
    });
  });

  group('what the bytes are', () {
    test('from the magic numbers, not the declaration', () {
      expect(sniffStickerFormat(_png()).mediaType, 'image/png');
      expect(sniffStickerFormat(_jpeg()).mediaType, 'image/jpeg');
      expect(sniffStickerFormat(_webp()).mediaType, 'image/webp');
      expect(sniffStickerFormat(_gif()).mediaType, 'image/gif');
    });

    test('an APNG says so, and only when the animation comes first', () {
      // `acTL` before the first `IDAT` is an APNG. After it, the file is a still
      // image with extra frames, and calling it animated would refuse a sticker
      // over frames a reader is allowed to ignore.
      expect(sniffStickerFormat(_png(animated: true)).mediaType, 'image/apng');
      expect(sniffStickerFormat(_png(animated: true)).animated, isTrue);
      expect(sniffStickerFormat(_png()).animated, isFalse);
    });

    test('a GIF is animated whatever this particular file holds', () {
      // The container can carry hundreds of frames and the only way to be sure
      // it carries one is to walk the frame list, which is decoding.
      expect(sniffStickerFormat(_gif()).animated, isTrue);
    });

    test('an animated WebP says so, a still one does not', () {
      expect(sniffStickerFormat(_webp(animated: true)).animated, isTrue);
      expect(sniffStickerFormat(_webp(animated: true)).mediaType, 'image/webp');
      expect(sniffStickerFormat(_webp()).animated, isFalse);
    });

    test('AVIF is identified as AVIF, so the refusal can name it', () {
      // Undecodable here, but *recognised*: "we could not read it" would be a
      // false statement about a file whose first twelve bytes we just read.
      expect(sniffStickerFormat(_avif()).mediaType, 'image/avif');
      expect(sniffStickerFormat(_avif()).animated, isFalse);
      expect(sniffStickerFormat(_avif(sequence: true)).animated, isTrue);
    });

    test('something unrecognised is not guessed at', () {
      expect(
        sniffStickerFormat(<int>[0, 1, 2, 3, 4]).mediaType,
        kUnknownMediaType,
      );
      expect(sniffStickerFormat(const <int>[]).mediaType, kUnknownMediaType);
    });

    test('a truncated signature is not a picture', () {
      // Two bytes of a PNG signature is not a PNG, and treating it as one would
      // hand those bytes to the PNG decoder.
      expect(
        sniffStickerFormat(<int>[0x89, 0x50]).mediaType,
        kUnknownMediaType,
      );
      expect(
        sniffStickerFormat(<int>[0x47, 0x49, 0x46]).mediaType,
        kUnknownMediaType,
      );
      expect(
        sniffStickerFormat(List<int>.filled(11, 0x41)).mediaType,
        kUnknownMediaType,
      );
    });

    test('a hostile chunk length does not walk off the end', () {
      // A 4 GB length claim in a 16 byte file. The scan must end there rather
      // than loop over a range nothing backs.
      final bytes = <int>[
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
        0xFF, 0xFF, 0xFF, 0xFF, //
        0x49, 0x44, 0x41, 0x54, // 'IDAT'
      ];
      expect(() => sniffStickerFormat(bytes), returnsNormally);
      expect(sniffStickerFormat(bytes).mediaType, 'image/png');
      expect(sniffStickerFormat(bytes).animated, isFalse);
    });
  });

  group('the integrity field', () {
    test('accepts both algorithms the XEP uses', () {
      expect(_sha1.isWellFormed, isTrue);
      expect(_sha256.isWellFormed, isTrue);
    });

    test('accepts hex as well as base64', () {
      // 64 hex digits is what a sha-256 looks like in hex; 40 would be a
      // truncated hash, which is refused below.
      expect(
        const StickerIntegrity(
          algorithm: 'sha-256',
          value:
              '0123456789abcdef0123456789abcdef'
              '0123456789abcdef0123456789abcdef',
        ).isWellFormed,
        isTrue,
      );
    });

    test('tolerates capitalisation and a wrapped element', () {
      // The same hash, written by a client that shout-cases the attribute and
      // pretty-prints the element. Refusing this would be refusing formatting.
      final shouted = StickerIntegrity(
        algorithm: 'SHA-256',
        value: ' ${_sha256.value}\n',
      );
      expect(shouted.isWellFormed, isTrue);
    });

    test('refuses a value it could not compare against', () {
      // A truncated hash is not a weak hash, it is no hash: there is nothing to
      // check a later fetch against.
      const truncated = StickerIntegrity(
        algorithm: 'sha-256',
        value: 'EpRv28DHHzFrE4zd+xaNpVb4',
      );
      expect(truncated.isWellFormed, isFalse);
      expect(
        const StickerIntegrity(
          algorithm: 'md5',
          value: 'deadbeef',
        ).isWellFormed,
        isFalse,
      );
      expect(
        const StickerIntegrity(algorithm: 'sha-1', value: '').isWellFormed,
        isFalse,
      );
    });

    test('a pack with no hash is not the same as a pack with a bad one', () {
      final none = StickerSafety.check(
        _candidate(_png(), item: _item(integrity: null)),
      );
      final bad = StickerSafety.check(
        _candidate(
          _png(),
          item: _item(
            integrity: const StickerIntegrity(algorithm: 'sha-256', value: 'x'),
          ),
        ),
      );
      expect(none.refusals, contains(StickerRefusal.missingIntegrity));
      expect(bad.refusals, contains(StickerRefusal.malformedIntegrity));
    });

    test('no hash means not cacheable, and nothing else', () {
      // This is the third answer, and the reason it exists separately: the
      // sticker is fine to send and fine to show. What it is not is *keepable*,
      // because with nothing to compare a later fetch against, a source that
      // starts serving a different image would never be noticed.
      final candidate = _candidate(_png(), item: _item(integrity: null));
      expect(isSafeToSend(candidate), isTrue);
      expect(isSafeToDisplay(candidate), isTrue);
      expect(isCacheable(candidate), isFalse);
      expect(StickerSafety.check(candidate).blockedSend, isNull);
    });

    test('a malformed hash does not stop a send either', () {
      final candidate = _candidate(
        _png(),
        item: _item(
          integrity: const StickerIntegrity(
            algorithm: 'sha-256',
            value: 'nope',
          ),
        ),
      );
      expect(isSafeToSend(candidate), isTrue);
      expect(isCacheable(candidate), isFalse);
    });
  });

  group('a declared type against the actual bytes', () {
    test('a declaration that contradicts the bytes is refused', () {
      // The whole reason the bytes get a say: the type field is written by
      // whoever published the pack, and believing it lets them choose which
      // decoder is handed these bytes.
      final bytes = _jpeg();
      final candidate = _candidate(bytes, item: _item(size: bytes.length));
      final verdict = StickerSafety.check(candidate);
      expect(verdict.refusals, contains(StickerRefusal.declaredTypeMismatch));
      expect(isSafeToSend(candidate), isFalse);
      expect(isSafeToDisplay(candidate), isFalse);
    });

    test('a declaration that agrees with the bytes is accepted', () {
      // The other side of the same test. A validator that only checks the first
      // direction has checked the easy one and proved nothing.
      final candidate = _candidate(_png());
      expect(StickerSafety.check(candidate).refusals, isEmpty);
      expect(isSafeToSend(candidate), isTrue);
      expect(isSafeToDisplay(candidate), isTrue);
      expect(isCacheable(candidate), isTrue);
    });

    test('a misspelt type is not a contradiction', () {
      // `image/jpg` is what a great many pack publishers write. The mismatch
      // rule catches a peer pointing our decoder at the wrong format; it is not
      // here to police how somebody spells a file extension.
      final bytes = _jpeg();
      expect(
        isSafeToSend(
          _candidate(
            bytes,
            item: _item(mediaType: 'image/jpg', size: bytes.length),
          ),
        ),
        isTrue,
      );
      expect(
        isSafeToSend(
          _candidate(_png(), item: _item(mediaType: 'image/png; charset=x')),
        ),
        isTrue,
      );
    });

    test('a missing declaration is not a contradiction either', () {
      // The pack said nothing about the type, but the bytes were measured, so
      // the gap costs the pack metadata completeness rather than us an image.
      final candidate = _candidate(_png(), item: _item(mediaType: ''));
      expect(StickerSafety.check(candidate).refusals, isEmpty);
    });

    test('an honest GIF is refused as animated and not as a lie', () {
      // The publisher told the truth and the file is still refused, so the reason
      // a caller shows has to be the animation, not a mismatch that did not
      // happen.
      final bytes = _gif();
      final verdict = StickerSafety.check(
        _candidate(
          bytes,
          item: _item(mediaType: 'image/gif', size: bytes.length),
        ),
      );
      expect(verdict.refusals, [StickerRefusal.animated]);
    });

    test('a GIF declared as a PNG is refused for both reasons', () {
      // Both are reported, and the type one first: a pack that misdescribes its
      // file is a different fact from a pack that ships an animation, and
      // reporting only the second hides the first.
      final bytes = _gif();
      final verdict = StickerSafety.check(
        _candidate(
          bytes,
          item: _item(mediaType: 'image/png', size: bytes.length),
        ),
      );
      expect(
        verdict.refusals,
        containsAll(<StickerRefusal>[
          StickerRefusal.declaredTypeMismatch,
          StickerRefusal.animated,
        ]),
      );
      expect(verdict.blockedDisplay, StickerRefusal.declaredTypeMismatch);
    });

    test('unidentifiable bytes get no mismatch verdict', () {
      // Asserting a mismatch against bytes we could not read would claim a
      // knowledge we do not have, and it would be quoted back at the sender.
      final bytes = <int>[0x00, 0x11, 0x22, 0x33, 0x44, 0x55];
      final verdict = StickerSafety.check(
        _candidate(
          bytes,
          item: _item(mediaType: 'image/png', size: bytes.length),
        ),
      );
      expect(verdict.refusals, [StickerRefusal.undecodableMediaType]);
    });

    test('a format we recognise but do not decode is refused by name', () {
      final bytes = _avif();
      final verdict = StickerSafety.check(
        _candidate(
          bytes,
          item: _item(mediaType: 'image/avif', size: bytes.length),
        ),
      );
      expect(verdict.refusals, [StickerRefusal.undecodableMediaType]);
      expect(
        isSafeToDisplay(StickerCandidate(item: _item(), bytes: bytes)),
        isFalse,
      );
    });
  });

  group('what may be sent', () {
    test('an oversized sticker is refused', () {
      // 256 KiB of sticker arrives at the server as roughly 460 KiB of
      // ciphertext, because the metadata is base64 inside an AEAD box that is
      // then base64'd again. Past that we are pushing a stanza at a limit the
      // server will enforce.
      final bytes = _png(fill: 300 * 1024);
      final candidate = _candidate(bytes);
      final verdict = StickerSafety.check(candidate);
      expect(verdict.refusals, contains(StickerRefusal.tooLarge));
      expect(isSafeToSend(candidate), isFalse);
      expect(verdict.blockedSend, StickerRefusal.tooLarge);
      expect(bytes.length, greaterThan(kStickerSendMaxBytes));
    });

    test('a declared size that disagrees with the bytes is refused', () {
      // The declared size is what a reader's fetcher budgets against, so this is
      // a peer who has found the one number we would have stopped reading at.
      final bytes = _png(fill: 4096);
      final candidate = _candidate(
        bytes,
        item: _item(mediaType: 'image/png', size: bytes.length + 5000),
      );
      final verdict = StickerSafety.check(candidate);
      expect(verdict.refusals, contains(StickerRefusal.declaredSizeDisagrees));
      expect(isSafeToSend(candidate), isFalse);
      expect(isCacheable(candidate), isFalse);
    });

    test('a sticker that understates its own size is refused', () {
      // The same attack from the other side, and the reason the comparison is an
      // equality rather than a ceiling: 40 MB announced as 2 KB.
      final bytes = _png(fill: 40 * 1024);
      final candidate = _candidate(bytes, item: _item(size: 2048));
      expect(
        StickerSafety.check(candidate).refusals,
        contains(StickerRefusal.declaredSizeDisagrees),
      );
      expect(isSafeToSend(candidate), isFalse);
    });

    test('a size of zero means the pack never said', () {
      // Not a disagreement, and refusing it would refuse every pack that omits
      // an optional field.
      final bytes = _png();
      expect(isSafeToSend(_candidate(bytes, item: _item(size: 0))), isTrue);
    });

    test('a zero dimension is refused', () {
      // An inline sticker reserves its box from these numbers, so zero is a
      // division by nowhere.
      final bytes = _png();
      for (final item in <StickerItem>[
        _item(size: bytes.length, width: 0),
        _item(size: bytes.length, height: 0),
        _item(size: bytes.length, width: -512),
      ]) {
        final candidate = _candidate(bytes, item: item);
        expect(
          StickerSafety.check(candidate).refusals,
          contains(StickerRefusal.unknownDimensions),
          reason: '$item',
        );
        expect(isSafeToSend(candidate), isFalse, reason: '$item');
        expect(isSafeToDisplay(candidate), isFalse, reason: '$item');
      }
    });

    test('an absurd aspect ratio is refused for sending and for display', () {
      // A decoder allocates w x h x 4 before it reads a pixel, so this is a
      // memory claim rather than a cosmetic one.
      final bytes = _png();
      final tall = _candidate(
        bytes,
        item: _item(size: bytes.length, width: 1, height: 100000),
      );
      expect(
        StickerSafety.check(tall).refusals,
        contains(StickerRefusal.absurdDimensions),
      );
      expect(isSafeToSend(tall), isFalse);
      expect(isSafeToDisplay(tall), isFalse);

      final huge = _candidate(
        bytes,
        item: _item(size: bytes.length, width: 40000, height: 40000),
      );
      expect(isSafeToDisplay(huge), isFalse);
    });

    test('a sticker with no fallback text is refused', () {
      // An empty `<desc/>` is an empty bubble on every client that cannot draw
      // the sticker, including the one that asked for it.
      final bytes = _png();
      final candidate = _candidate(
        bytes,
        item: _item(size: bytes.length, description: '   '),
      );
      final verdict = StickerSafety.check(candidate);
      expect(verdict.refusals, contains(StickerRefusal.noFallbackText));
      expect(isSafeToSend(candidate), isFalse);
      // Shown anyway: the picture is right there, and the text is only needed by
      // a client that cannot draw it.
      expect(isSafeToDisplay(candidate), isTrue);
    });

    test('a source that is not a URL is refused', () {
      // The URI is untrusted input to an HTTP client, and a pack from a stranger
      // can put anything in it.
      final bytes = _png();
      for (final sources in <List<String>>[
        <String>['file:///data/data/com.example/cache/sticker.png'],
        <String>['data:image/png;base64,iVBORw0KGgo='],
        <String>['javascript:alert(1)'],
        <String>['https://cdn.example/a.png\r\nX-Evil: 1'],
        <String>[],
      ]) {
        final candidate = _candidate(
          bytes,
          item: _item(size: bytes.length, sources: sources),
        );
        expect(
          StickerSafety.check(candidate).refusals,
          contains(StickerRefusal.unusableSource),
          reason: '$sources',
        );
        expect(isSafeToDisplay(candidate), isFalse, reason: '$sources');
      }
    });

    test('a plain http source is allowed', () {
      // Not leniency: the pack's size is checked against what arrives and the
      // hash against the bytes, so a network that substitutes is caught twice.
      final bytes = _png();
      expect(
        isSafeToDisplay(
          _candidate(
            bytes,
            item: _item(
              size: bytes.length,
              sources: <String>['http://cdn.example/a.png'],
            ),
          ),
        ),
        isTrue,
      );
    });

    test('an item with no bytes is not sendable and not displayable', () {
      // A pack listing, not an attachment: sending means attaching a file, and
      // there is nothing to draw either. Caching the metadata is exactly what a
      // listing is for.
      final candidate = StickerCandidate(item: _item(size: 70000));
      final verdict = StickerSafety.check(candidate);
      expect(verdict.refusals, contains(StickerRefusal.bytesUnavailable));
      expect(isSafeToSend(candidate), isFalse);
      expect(isSafeToDisplay(candidate), isFalse);
      expect(isCacheable(candidate), isTrue);
    });

    test('every refusal has something to say about itself', () {
      // A refusal nobody can word is a refusal the UI can only render as a shrug.
      for (final refusal in StickerRefusal.values) {
        expect(refusal.reason, isNotEmpty, reason: '$refusal');
        expect(refusal.reason.endsWith('.'), isTrue, reason: '$refusal');
      }
    });

    test('the policy table is the one this file documents', () {
      // Pinned so that adding a refusal cannot quietly change what it blocks.
      // Every value except the two hash rules blocks a send.
      for (final refusal in StickerRefusal.values) {
        final isHashRule =
            refusal == StickerRefusal.missingIntegrity ||
            refusal == StickerRefusal.malformedIntegrity;
        expect(refusal.blocksSend, isNot(isHashRule), reason: '$refusal');
      }
      // Nothing but our own metadata and our own budgets may stop a display.
      const displayStoppers = <StickerRefusal>{
        StickerRefusal.undecodableMediaType,
        StickerRefusal.declaredTypeMismatch,
        StickerRefusal.animated,
        StickerRefusal.unknownDimensions,
        StickerRefusal.absurdDimensions,
        StickerRefusal.bytesUnavailable,
        StickerRefusal.unusableSource,
      };
      for (final refusal in StickerRefusal.values) {
        expect(
          refusal.blocksDisplay,
          displayStoppers.contains(refusal),
          reason: '$refusal',
        );
      }
      for (final refusal in <StickerRefusal>[
        StickerRefusal.tooLarge,
        StickerRefusal.missingIntegrity,
        StickerRefusal.malformedIntegrity,
      ]) {
        expect(refusal.blocksCaching, isTrue, reason: '$refusal');
      }
    });
  });

  group('sending is not displaying', () {
    test('a 300 KiB sticker is refused for sending and shown anyway', () {
      // Which is which, and why:
      //
      //   send: no. 300 KiB of sticker plus metadata is roughly 460 KiB of
      //   ciphertext in one stanza, and the cap is a budget for what we are
      //   willing to put on the wire.
      //
      //   display: yes. The bytes already arrived and have already been paid
      //   for. Refusing to *show* a picture somebody chose for us because of our
      //   own outgoing budget would be this client rewriting their message, and
      //   the fallback text stands in for it on any client that cannot draw it.
      final bytes = _png(fill: 300 * 1024);
      final candidate = _candidate(bytes);

      expect(isSafeToSend(candidate), isFalse, reason: 'send');
      expect(isSafeToDisplay(candidate), isTrue, reason: 'display');

      final verdict = StickerSafety.check(candidate);
      expect(verdict.blockedSend, StickerRefusal.tooLarge);
      expect(verdict.blockedDisplay, isNull);
      // Not cacheable either: past the cache cap it is a download, not a cache
      // entry, and a cache with no bound is how a phone runs out of room.
      expect(isCacheable(candidate), isFalse);
    });

    test('a sticker that is not square is refused as a sticker, not as a picture', () {
      // send: no. A conforming client draws stickers in a fixed box, so a 3:2
      // sticker is letterboxed however we label it. The right outcome for a
      // picture the user chose that is not square is to send it as the photo it
      // is.
      //
      // display: yes. It is a perfectly good image and they picked it.
      final bytes = _png();
      final candidate = _candidate(
        bytes,
        item: _item(size: bytes.length, width: 512, height: 341),
      );

      expect(isSafeToSend(candidate), isFalse, reason: 'send');
      expect(isSafeToDisplay(candidate), isTrue, reason: 'display');
      expect(
        StickerSafety.check(candidate).blockedSend,
        StickerRefusal.notSquare,
      );
    });

    test('an animation is refused on both sides', () {
      // The one sticker where the two answers agree, and it is worth saying why
      // this is not merely "animated is unsafe": XEP-0449 §5 notes that
      // flickering stickers can induce seizures, and an animation is the one
      // image feature whose cost the sender does not get to choose.
      final bytes = _gif();
      final candidate = _candidate(
        bytes,
        item: _item(mediaType: 'image/gif', size: bytes.length),
      );

      expect(isSafeToSend(candidate), isFalse);
      expect(isSafeToDisplay(candidate), isFalse);
      expect(
        StickerSafety.check(candidate).blockedDisplay,
        StickerRefusal.animated,
      );
    });
  });

  group('the stanza shape', () {
    final bytes = _png();
    final candidate = _candidate(bytes);

    test('names the two elements a send needs', () {
      final shape = stickerSendShape(candidate: candidate);
      expect(shape, isNotNull);
      expect(shape!.marker.tag, 'sticker');
      expect(shape.marker.xmlns, kStickersNamespace);
      expect(shape.fileSharing.tag, 'file-sharing');
      expect(shape.fileSharing.xmlns, kSfsNamespace);
    });

    test('goes inside the encrypted payload, and offers nothing else', () {
      // The one assertion in this file that protects a design decision rather
      // than a behaviour. A sticker is content: the metadata says as much about
      // the conversation as the body would, so both nodes travel encrypted — the
      // opposite of a reaction, which travels in the clear because it is
      // metadata *about* a message and is meaningless without one.
      //
      // `publicNodes` exists so that "do not put this in the clear" is something
      // a caller can see and a test can assert, rather than a rule in a comment
      // that a caller has to remember.
      final shape = stickerSendShape(candidate: candidate)!;
      expect(shape.encryptedPayloadNodes, hasLength(2));
      expect(shape.publicNodes, isEmpty);
    });

    test('carries the measured type and size, not the declared ones', () {
      // For an outgoing sticker the bytes are ours, so the pack's claims about
      // them are absent or wrong. Publishing them would put a claim this client
      // has already disproved into a pack other people will fetch.
      final shape = stickerSendShape(
        candidate: StickerCandidate(
          item: _item(mediaType: '', size: bytes.length),
          bytes: bytes,
        ),
      )!;
      final file = shape.fileSharing.child('file');
      expect(file!.xmlns, kFileMetadataNamespace);
      expect(file.child('media-type')!.text, 'image/png');
      expect(file.child('size')!.text, '${bytes.length}');
      expect(file.child('dimensions')!.text, '512x512');
      expect(file.child('desc')!.text, '😘');
    });

    test('carries the hash the peer will check the download against', () {
      final shape = stickerSendShape(candidate: candidate)!;
      final hash = shape.fileSharing.descendant('hash')!;
      expect(hash.xmlns, kHashesNamespace);
      expect(hash.attributes['algo'], 'sha-256');
      expect(hash.text, _sha256.value);
    });

    test('carries where to fetch it', () {
      final shape = stickerSendShape(candidate: candidate)!;
      final target = shape.fileSharing.descendant('url-data')!;
      expect(target.xmlns, kUrlDataNamespace);
      expect(target.attributes['target'], 'https://cdn.example/marsey.png');
    });

    test('names the pack only when there is one', () {
      // XEP-0449 lets a sticker be sent with no pack at all, and inventing one
      // to hold a sticker the user picked by hand would publish something false.
      final bare = stickerSendShape(candidate: candidate)!;
      expect(bare.marker.attributes, isEmpty);

      final onPep = stickerSendShape(
        candidate: candidate,
        pack: parsePackUri(_xepPackUri),
      )!;
      expect(onPep.marker.attributes, <String, String>{'pack': _packItemId});

      final elsewhere = stickerSendShape(
        candidate: candidate,
        pack: const StickerPackUri(
          publisher: 'pubsub.shakespeare.lit',
          node: 'stickers',
          itemId: _packItemId,
        ),
      )!;
      // `jid` and `node` only when the pack is not on the sender's own PEP node,
      // which is the rule in §4.4.
      expect(elsewhere.marker.attributes, <String, String>{
        'pack': _packItemId,
        'jid': 'pubsub.shakespeare.lit',
        'node': 'stickers',
      });
    });

    test('the only cleartext is the fallback the sender chose', () {
      final shape = stickerSendShape(candidate: candidate)!;
      expect(shape.cleartextBody, '😘');
      expect(
        shape.cleartextBody,
        shape.fileSharing.child('file')!.child('desc')!.text,
      );
    });

    test('is not available for a sticker this file will not send', () {
      // There is no second shape that drops the checks. A sticker refused here
      // is refused as a sticker — not sent as a plain message, and not sent with
      // the metadata left off.
      final tooBig = _candidate(_png(fill: 300 * 1024));
      expect(stickerSendShape(candidate: tooBig), isNull);

      final lying = _candidate(bytes, item: _item(size: 12));
      expect(stickerSendShape(candidate: lying), isNull);

      final noHash = _candidate(bytes, item: _item(integrity: null));
      expect(stickerSendShape(candidate: noHash), isNull);

      final noSource = _candidate(
        bytes,
        item: _item(sources: const <String>[]),
      );
      expect(stickerSendShape(candidate: noSource), isNull);

      final noText = _candidate(bytes, item: _item(description: ''));
      expect(stickerSendShape(candidate: noText), isNull);
    });

    test('checks the sources the caller just uploaded to', () {
      // The override has not been through the item's own check, so it is checked
      // rather than assumed: an upload that produced no usable URL has produced
      // no sticker.
      expect(
        stickerSendShape(
          candidate: candidate,
          sourceUris: <String>['file:///data/user/0/app/cache/1.png'],
        ),
        isNull,
      );
      expect(
        stickerSendShape(candidate: candidate, sourceUris: const <String>[]),
        isNull,
      );
      expect(
        stickerSendShape(
          candidate: candidate,
          sourceUris: <String>['https://upload.example/abc123'],
        ),
        isNotNull,
      );
    });
  });
}
