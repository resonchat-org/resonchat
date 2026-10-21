// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';

import 'package:test/test.dart';

import 'package:resonchat/xmpp/chat/sticker_link.dart';

void main() {
  final now = DateTime.utc(2026, 6, 1, 12);

  test('an empty link is not sendable', () {
    expect(
      stickerLinkUsable(
        url: '',
        uploadedAt: now,
        kind: StickerSendKind.plain,
        now: now,
      ),
      isFalse,
    );
    expect(
      stickerLinkUsable(
        url: 'https://files.example/a',
        uploadedAt: null,
        kind: StickerSendKind.plain,
        now: now,
      ),
      isFalse,
    );
  });

  test('each mode accepts only its own scheme', () {
    const https = 'https://files.example/a';
    const aes = 'aesgcm://files.example/a#abcd';
    expect(
      stickerLinkUsable(
        url: https,
        uploadedAt: now,
        kind: StickerSendKind.plain,
        now: now,
      ),
      isTrue,
    );
    expect(
      stickerLinkUsable(
        url: https,
        uploadedAt: now,
        kind: StickerSendKind.omemo,
        now: now,
      ),
      isFalse,
    );
    expect(
      stickerLinkUsable(
        url: aes,
        uploadedAt: now,
        kind: StickerSendKind.omemo,
        now: now,
      ),
      isTrue,
    );
    expect(
      stickerLinkUsable(
        url: aes,
        uploadedAt: now,
        kind: StickerSendKind.pq,
        now: now,
      ),
      isTrue,
    );
    expect(
      stickerLinkUsable(
        url: aes,
        uploadedAt: now,
        kind: StickerSendKind.plain,
        now: now,
      ),
      isFalse,
    );
  });

  test('image hash is sha256 of the bytes', () async {
    expect(
      await stickerContentHash(utf8.encode('abc')),
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
  });

  test('a link older than 30 days is uploaded again', () {
    final fresh = now.subtract(const Duration(days: 30));
    final stale = now.subtract(const Duration(days: 30, seconds: 1));
    expect(
      stickerLinkUsable(
        url: 'https://files.example/a',
        uploadedAt: fresh,
        kind: StickerSendKind.plain,
        now: now,
      ),
      isTrue,
    );
    expect(
      stickerLinkUsable(
        url: 'aesgcm://files.example/a#k',
        uploadedAt: stale,
        kind: StickerSendKind.pq,
        now: now,
      ),
      isFalse,
    );
  });
}
