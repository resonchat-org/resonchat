// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Per-conversation appearance.
//
// One thing dominates: this is stored as a short opaque string, so every read of
// it has to survive a value it does not recognise. A conversation that cannot be
// opened because its wallpaper setting is from a build that no longer exists is
// a much worse outcome than a conversation with the wrong wallpaper.

import 'package:flutter/material.dart';

import 'package:drift/native.dart';
import 'package:test/test.dart';

import 'package:resonchat/persistence/database.dart';
import 'package:resonchat/ui/chat/appearance.dart';

void main() {
  group('encoding', () {
    test('round trips a full appearance', () {
      const original = ChatAppearance(
        wallpaper: Wallpaper.rings,
        bubble: BubbleStyle.asymmetric,
      );
      final decoded = ChatAppearance.decode(original.encode());
      expect(decoded.wallpaper, Wallpaper.rings);
      expect(decoded.bubble, BubbleStyle.asymmetric);
    });

    test('the default encodes as zeros', () {
      expect(const ChatAppearance().encode(), '00');
    });

    test('custom wallpaper round trips', () {
      const original = ChatAppearance(
        wallpaper: Wallpaper.custom,
        bubble: BubbleStyle.square,
      );
      final decoded = ChatAppearance.decode(original.encode());
      expect(decoded.wallpaper, Wallpaper.custom);
      expect(decoded.bubble, BubbleStyle.square);
    });
  });

  group('reading a value we do not understand', () {
    test('null gives the default', () {
      final a = ChatAppearance.decode(null);
      expect(a.wallpaper, Wallpaper.none);
      expect(a.bubble, BubbleStyle.rounded);
    });

    test('an empty string gives the default', () {
      expect(ChatAppearance.decode('').wallpaper, Wallpaper.none);
    });

    test('a truncated string does not throw', () {
      for (final raw in const ['', '1', '12', '1234']) {
        expect(ChatAppearance.decode(raw), isNotNull, reason: 'raw="$raw"');
      }
    });

    test('an out-of-range index falls back rather than throwing', () {
      final a = ChatAppearance.decode('99');
      expect(a.wallpaper, Wallpaper.none);
      expect(a.bubble, BubbleStyle.rounded);
    });

    test('extra trailing characters are ignored', () {
      final a = ChatAppearance.decode('10???');
      expect(a.wallpaper, Wallpaper.dots);
      expect(a.bubble, BubbleStyle.rounded);
    });
  });

  group('bubble corners', () {
    test('rounded and square are what they say', () {
      expect(
        bubbleRadii(BubbleStyle.rounded, true).topLeft,
        const Radius.circular(14),
      );
      expect(
        bubbleRadii(BubbleStyle.square, true).topLeft,
        const Radius.circular(4),
      );
    });

    test('asymmetric points the far corner away from the sender', () {
      final mine = bubbleRadii(BubbleStyle.asymmetric, true);
      final theirs = bubbleRadii(BubbleStyle.asymmetric, false);
      expect(mine.topLeft, const Radius.circular(4));
      expect(mine.topRight, const Radius.circular(14));
      expect(theirs.topLeft, const Radius.circular(14));
      expect(theirs.topRight, const Radius.circular(4));
    });

    test('the two sides are mirror images of each other', () {
      final mine = bubbleRadii(BubbleStyle.asymmetric, true);
      final theirs = bubbleRadii(BubbleStyle.asymmetric, false);
      expect(mine.topLeft, theirs.topRight);
      expect(mine.bottomRight, theirs.bottomLeft);
    });

    test('both sides have the same total corner radius', () {
      double sum(BorderRadius r) =>
          r.topLeft.x + r.topRight.x + r.bottomLeft.x + r.bottomRight.x;
      expect(
        sum(bubbleRadii(BubbleStyle.asymmetric, true)),
        sum(bubbleRadii(BubbleStyle.asymmetric, false)),
      );
    });
  });

  group('the painter', () {
    test('repaints only when something visible changed', () {
      final a = WallpaperPainter(
        wallpaper: Wallpaper.dots,
        base: Colors.white,
        accent: Colors.blue,
        seed: 'a@example.org',
      );
      final same = WallpaperPainter(
        wallpaper: Wallpaper.dots,
        base: Colors.white,
        accent: Colors.blue,
        seed: 'a@example.org',
      );
      expect(a.shouldRepaint(same), isFalse);

      final other = WallpaperPainter(
        wallpaper: Wallpaper.stripes,
        base: Colors.white,
        accent: Colors.blue,
        seed: 'a@example.org',
      );
      expect(a.shouldRepaint(other), isTrue);
    });

    test('a different conversation repaints, since the offset differs', () {
      final a = WallpaperPainter(
        wallpaper: Wallpaper.dots,
        base: Colors.white,
        accent: Colors.blue,
        seed: 'a@example.org',
      );
      final other = WallpaperPainter(
        wallpaper: Wallpaper.dots,
        base: Colors.white,
        accent: Colors.blue,
        seed: 'b@example.org',
      );
      expect(a.shouldRepaint(other), isTrue);
    });

    test('painting every wallpaper does not throw on an empty size', () {
      for (final w in Wallpaper.values) {
        final painter = WallpaperPainter(
          wallpaper: w,
          base: Colors.white,
          accent: Colors.blue,
          seed: 'x',
        );
        expect(
          () => painter.paint(_RecordingCanvas(), const Size(0, 0)),
          returnsNormally,
          reason: w.name,
        );
      }
    });
  });

  group('storage', () {
    late AppDatabase db;
    setUp(() => db = AppDatabase(NativeDatabase.memory()));
    tearDown(() => db.close());

    Future<String?> appearanceOf(String jid) async {
      final rows = await db.watchChats().first;
      for (final c in rows) {
        if (c.jid == jid) return c.appearance;
      }
      return null;
    }

    test('a conversation starts with no override', () async {
      await db.upsertChat('a@example.org');
      expect(await appearanceOf('a@example.org'), '');
    });

    test('round trips', () async {
      await db.upsertChat('a@example.org');
      const a = ChatAppearance(wallpaper: Wallpaper.stripes);
      await db.setChatAppearance('a@example.org', a.encode());
      expect(
        ChatAppearance.decode(await appearanceOf('a@example.org')).wallpaper,
        Wallpaper.stripes,
      );
    });

    test('is per conversation', () async {
      await db.upsertChat('a@example.org');
      await db.upsertChat('b@example.org');
      await db.setChatAppearance('a@example.org', '20');
      expect(await appearanceOf('b@example.org'), '');
    });

    test('can be set before the conversation has a row', () async {
      await db.setChatAppearance('new@example.org', '11');
      expect(
        ChatAppearance.decode(await appearanceOf('new@example.org')).wallpaper,
        Wallpaper.dots,
      );
    });

    test('clearing restores the default rather than storing a default', () {
      return db.setChatAppearance('a@example.org', '20').then((_) async {
        await db.setChatAppearance('a@example.org', null);
        expect(await appearanceOf('a@example.org'), '');
        expect(ChatAppearance.decode('').wallpaper, Wallpaper.none);
      });
    });
  });
}

/// A canvas that records nothing, so the painter can be run for its exceptions
/// alone.
class _RecordingCanvas implements Canvas {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
