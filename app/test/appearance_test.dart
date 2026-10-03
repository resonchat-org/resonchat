// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Per-conversation appearance.
//
// One thing dominates: this is stored as a short opaque string, so every read of
// it has to survive a value it does not recognise. A conversation that cannot be
// opened because its wallpaper setting is from a build that no longer exists is
// a much worse outcome than a conversation with the wrong wallpaper.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:test/test.dart';
import 'package:resonchat/store/database.dart';
import 'package:resonchat/ui/appearance.dart';

void main() {
  group('encoding', () {
    test('round trips a full appearance', () {
      final original = ChatAppearance(
        wallpaper: Wallpaper.rings,
        bubble: BubbleStyle.asymmetric,
        accent: HSLColor.fromAHSL(1, 210, 0.55, 0.5).toColor(),
      );
      final decoded = ChatAppearance.decode(original.encode());
      expect(decoded.wallpaper, Wallpaper.rings);
      expect(decoded.bubble, BubbleStyle.asymmetric);
      expect(
        HSLColor.fromColor(decoded.accent!).hue.round(),
        HSLColor.fromColor(original.accent!).hue.round(),
      );
    });

    test('the default encodes without an accent', () {
      const plain = ChatAppearance();
      expect(plain.accent, isNull);
      expect(ChatAppearance.decode(plain.encode()).accent, isNull);
    });

    test('accent hue survives to within a degree', () {
      // Stored as three digits of hue rather than a full colour, so a hue at
      // the top of the circle must still come back recognisable.
      for (var hue = 0; hue < 360; hue += 17) {
        final colour = HSLColor.fromAHSL(1, hue.toDouble(), 0.55, 0.5).toColor();
        final back = ChatAppearance.decode(
          ChatAppearance(accent: colour).encode(),
        );
        final diff = (HSLColor.fromColor(back.accent!).hue.round() - hue)
            .abs();
        expect(diff <= 1, isTrue, reason: 'hue $hue came back off by $diff');
      }
    });
  });

  group('reading a value we do not understand', () {
    test('null gives the default', () {
      final a = ChatAppearance.decode(null);
      expect(a.wallpaper, Wallpaper.none);
      expect(a.bubble, BubbleStyle.rounded);
      expect(a.accent, isNull);
    });

    test('an empty string gives the default', () {
      expect(ChatAppearance.decode('').wallpaper, Wallpaper.none);
    });

    test('a truncated string does not throw', () {
      // A row written by a build that had a bug must not make a conversation
      // unopenable.
      for (final raw in const ['', '1', '12', '1234']) {
        expect(ChatAppearance.decode(raw), isNotNull, reason: 'raw="$raw"');
      }
    });

    test('an out-of-range index falls back rather than throwing', () {
      // '9' is past the end of both enums. The point is that neither read
      // throws — a row written by a build with more wallpapers must not make a
      // conversation unopenable.
      final a = ChatAppearance.decode('992');
      expect(a.wallpaper, Wallpaper.none);
      expect(a.bubble, BubbleStyle.rounded);
    });

    test('a valid index is used even when the hue is nonsense', () {
      // Decoding is per-field: one unreadable part does not discard the rest,
      // because losing the wallpaper because the accent string is corrupt is a
      // worse outcome than drawing no accent.
      // Index 1 for the wallpaper, 0 for the bubble: both valid, so the only
      // unreadable part is the hue.
      final a = ChatAppearance.decode('10???');
      expect(a.wallpaper, Wallpaper.dots);
      expect(a.bubble, BubbleStyle.rounded);
      expect(a.accent, isNull);
    });

    test('an unparseable hue means "no accent override"', () {
      final a = ChatAppearance.decode('11zzz');
      expect(a.wallpaper, Wallpaper.dots);
      expect(a.accent, isNull);
    });
  });

  group('bubble corners', () {
    test('rounded and square are what they say', () {
      expect(bubbleRadii(BubbleStyle.rounded, true).topLeft,
          const Radius.circular(14));
      expect(bubbleRadii(BubbleStyle.square, true).topLeft,
          const Radius.circular(4));
    });

    test('asymmetric points the far corner away from the sender', () {
      // Our own bubble is square on the left, so the corner nearest the other
      // party is the pointed one. Getting this backwards makes every bubble
      // look like it belongs to the wrong person.
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
      // It sits behind every message, so a repaint on every frame would be a
      // repaint of the whole transcript on every frame.
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
      // A zero-size canvas happens during the first layout pass, and a painter
      // that throws there takes the chat page down with it.
      for (final w in Wallpaper.values) {
        final painter = WallpaperPainter(
          wallpaper: w,
          base: Colors.white,
          accent: Colors.blue,
          seed: 'x',
        );
        expect(
          () => painter.paint(
            _RecordingCanvas(),
            const Size(0, 0),
          ),
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
      expect(ChatAppearance.decode(await appearanceOf('a@example.org')).wallpaper,
          Wallpaper.stripes);
    });

    test('is per conversation', () async {
      await db.upsertChat('a@example.org');
      await db.upsertChat('b@example.org');
      await db.setChatAppearance('a@example.org', '20');
      expect(await appearanceOf('b@example.org'), '');
    });

    test('can be set before the conversation has a row', () async {
      await db.setChatAppearance('new@example.org', '11');
      expect(ChatAppearance.decode(await appearanceOf('new@example.org'))
          .wallpaper, Wallpaper.dots);
    });

    test('clearing restores the default rather than storing a default', () {
      // A row of defaults is a list of conversations that once had a setting,
      // and it would stop a later change of the app's own defaults from
      // reaching them.
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
