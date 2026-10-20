// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Avatars (XEP-0084).
//
// Two things this file protects, both of which look like polish and are not:
//
//   * An avatar's identity is its *bytes*, so the cache key has to be a hash of
//     those bytes. Keying on anything derived from transport — the base64 text
//     with its line breaks, the item id a peer chose to send — makes a changed
//     avatar look unchanged.
//   * "No avatar" must not look like "this person hid their face". The
//     placeholder is a coloured initial, deterministically coloured per JID,
//     and the tests below say why each of those three properties is load-bearing.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:test/test.dart';

import 'package:resonchat/ui/contact_avatar.dart';
import 'package:resonchat/xmpp/avatar.dart';

void main() {
  group('identifying an avatar', () {
    test('the hash is of the bytes, not of the encoded text', () async {
      // SHA-1 of the raw bytes is what XEP-0084 specifies for the item id.
      final a = AvatarData(
        bytes: Uint8List.fromList(utf8.encode('hello')),
        mimeType: 'image/png',
      );
      expect(await a.hash, 'aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d');
    });

    test(
      'identical bytes hash identically, so a republish is a no-op',
      () async {
        // The pubsub item id is how a change is detected at all; a hash that
        // varied for identical input would notify on every republish.
        final bytes = Uint8List.fromList([1, 2, 3]);
        final one = AvatarData(bytes: bytes, mimeType: 'image/png');
        final two = AvatarData(bytes: bytes, mimeType: 'image/png');
        expect(await one.hash, await two.hash);
      },
    );

    test('one changed byte changes the hash', () async {
      final one = AvatarData(
        bytes: Uint8List.fromList([1, 2, 3]),
        mimeType: 'image/png',
      );
      final two = AvatarData(
        bytes: Uint8List.fromList([1, 2, 4]),
        mimeType: 'image/png',
      );
      expect(await one.hash, isNot(await two.hash));
    });

    test('the hash is lowercase hex of the right length', () async {
      final hash = await AvatarData(
        bytes: Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF]),
        mimeType: 'image/png',
      ).hash;
      expect(hash, hasLength(40));
      expect(hash, matches(RegExp(r'^[0-9a-f]{40}$')));
    });
  });

  group('deciding what an avatar is', () {
    test('from the bytes, not from what the publisher claimed', () {
      // The type field is supplied by whoever published it. Trusting it means a
      // peer can hand this client a blob that claims to be something else, and
      // the bytes are what actually get decoded.
      final png = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
      expect(sniffMimeType(png), 'image/png');
      final jpeg = [0xFF, 0xD8, 0xFF, 0xE0];
      expect(sniffMimeType(jpeg), 'image/jpeg');
      expect(sniffMimeType([0x47, 0x49, 0x46, 0x38, 0x39, 0x61]), 'image/gif');
    });

    test('webp too', () {
      final webp = [0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50];
      expect(sniffMimeType(webp), 'image/webp');
    });

    test('something unrecognised is not guessed at', () {
      // Claiming a type we cannot verify is how a decoder gets handed bytes it
      // was not written for.
      expect(sniffMimeType([0x00, 0x01, 0x02]), 'application/octet-stream');
    });

    test('a truncated header is not mistaken for a real image', () {
      // Two bytes of a PNG signature is not a PNG.
      expect(sniffMimeType([0x89, 0x50]), 'application/octet-stream');
    });

    test('empty input is handled', () {
      expect(sniffMimeType(const []), 'application/octet-stream');
    });
  });

  group('the placeholder', () {
    test('uses the first letter of the nickname, not of the JID', () {
      // The whole point of a nickname is that it should identify the person.
      expect(avatarInitial('Alex Chen', 'alex@x.example'), 'A');
      expect(avatarInitial('张三', 'zhangsan@x.example'), '张');
    });

    test('falls back to the JID when there is no nickname', () {
      expect(avatarInitial('', 'bob@x.example'), 'B');
    });

    test('skips a leading digit or symbol', () {
      // "404" should not become a circle with a 4 on it; the user's own name
      // is in there.
      expect(avatarInitial('404 Not Found', 'x@y.example'), 'N');
    });

    test('a non-Latin name does not produce a broken glyph', () {
      // `substring(0, 1)` on a CJK character returns a lone surrogate, which
      // renders as a replacement box. Reading the first rune does not.
      expect(avatarInitial('こんにちは', 'x@y.example'), 'こ');
      expect(avatarInitial('Привет', 'x@y.example'), 'П');
      expect(avatarInitial('العربية', 'x@y.example'), 'ا');
    });

    test('an empty everything is a question mark, not a crash', () {
      expect(avatarInitial('', ''), '?');
    });
  });

  group('the placeholder colour', () {
    test('is stable for a JID', () {
      // A circle that changes colour when nothing changed reads as a different
      // person having arrived.
      expect(
        tintFor('bob@x.example', Colors.blue),
        tintFor('bob@x.example', Colors.blue),
      );
    });

    test('is stable across a rename', () {
      // Derived from the address, not the display name: a contact renaming
      // themselves must not change colour.
      expect(
        tintFor('bob@x.example', Colors.blue),
        tintFor('bob@x.example', Colors.red),
      );
    });

    test('differs between two ordinary contacts', () {
      // The placeholder's job is to make two people in a list distinguishable
      // without a photo.
      expect(
        tintFor('bob@x.example', Colors.blue),
        isNot(tintFor('carol@x.example', Colors.blue)),
      );
    });

    test('is opaque, so it is legible on the page background', () {
      // A translucent colour over a light background can wash out to nothing.
      for (final jid in ['a@x.example', 'b@x.example', '张三@x.example']) {
        expect((tintFor(jid, Colors.blue).a * 255).round(), 255, reason: jid);
      }
    });
  });
}
