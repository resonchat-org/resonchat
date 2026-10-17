// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The design tokens.
//
// These tests are about **legibility**, because that is the property of a colour
// set that actually fails in the field. A palette that looks fine in a design
// review is routinely unreadable on a cheap panel in sunlight, and a chat
// transcript where you cannot read the timestamp is a chat transcript you will
// get support requests about.
//
// The contrast thresholds are WCAG 2.1: 4.5:1 for body text, 3:1 for large
// text and for non-text UI that carries meaning (a badge, an icon). Both are
// checked here so a future palette edit cannot silently regress them.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonchat/ui/design_tokens.dart';

/// Relative luminance per WCAG 2.1.
double _luminance(Color c) {
  double channel(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
}

/// Contrast ratio between two opaque colours, 1.0 to 21.0.
double _contrast(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

ColorScheme _scheme(Brightness b) =>
    ColorScheme.fromSeed(seedColor: const Color(0xFF2A6FD6), brightness: b);

void main() {
  final palettes = {
    'dark': XColors.dark(_scheme(Brightness.dark)),
    'light': XColors.light(_scheme(Brightness.light)),
  };

  group('body text is readable on every surface it sits on', () {
    for (final entry in palettes.entries) {
      final name = entry.key;
      final x = entry.value;

      test('$name — primary text on the page', () {
        expect(
          _contrast(x.textPrimary, x.canvas),
          greaterThanOrEqualTo(4.5),
          reason: '$name textPrimary on canvas',
        );
      });

      test('$name — primary text inside both bubbles', () {
        // The two bubble colours are the surfaces a user reads the most text
        // on, and they differ from the canvas, so they are checked separately.
        expect(
          _contrast(x.onOwnBubble, x.ownBubble),
          greaterThanOrEqualTo(4.5),
          reason: '$name own bubble',
        );
        expect(
          _contrast(x.onPeerBubble, x.peerBubble),
          greaterThanOrEqualTo(4.5),
          reason: '$name peer bubble',
        );
      });

      test('$name — secondary text is still readable', () {
        // Secondary is where timestamps and previews live, so it is the text
        // most likely to be complained about. It gets the body threshold, not
        // a reduced one.
        expect(
          _contrast(x.textSecondary, x.canvas),
          greaterThanOrEqualTo(4.5),
          reason: '$name textSecondary on canvas',
        );
        expect(
          _contrast(x.textSecondary, x.surface),
          greaterThanOrEqualTo(4.5),
          reason: '$name textSecondary on surface',
        );
      });

      test('$name — tertiary text meets the large-text threshold', () {
        // Deliberately the lower bar: this is the "sent" tick and a field
        // hint. It is allowed to be quiet, but not to be invisible.
        expect(
          _contrast(x.textTertiary, x.canvas),
          greaterThanOrEqualTo(3.0),
          reason: '$name textTertiary on canvas',
        );
      });
    }
  });

  group('meaningful non-text elements meet 3:1', () {
    for (final entry in palettes.entries) {
      final name = entry.key;
      final x = entry.value;

      test('$name — the unread badge against its own background', () {
        // A badge nobody can see is an unread count that does not exist, which
        // is the whole feature failing silently.
        expect(
          _contrast(x.onAccent, x.unreadBadge),
          greaterThanOrEqualTo(4.5),
          reason: '$name badge count on badge fill',
        );
      });

      test('$name — the accent against the page', () {
        // The lock icon in the chat list, the selected tab: these carry meaning
        // without text and must be distinguishable from the background.
        expect(
          _contrast(x.accent, x.canvas),
          greaterThanOrEqualTo(3.0),
          reason: '$name accent on canvas',
        );
      });

      test('$name — danger against the page', () {
        expect(
          _contrast(x.danger, x.canvas),
          greaterThanOrEqualTo(3.0),
          reason: '$name danger on canvas',
        );
      });

      test('$name — online against the page', () {
        expect(
          _contrast(x.online, x.canvas),
          greaterThanOrEqualTo(3.0),
          reason: '$name online on canvas',
        );
      });
    }
  });

  group('surfaces are actually distinguishable from each other', () {
    for (final entry in palettes.entries) {
      final name = entry.key;
      final x = entry.value;

      test('$name — canvas, surface and raised differ', () {
        // Flat elevation has no other cue: if two surfaces are the same
        // colour, a sheet and the page behind it merge into one shape and the
        // user loses the sense of depth the layout is expressing.
        expect(x.canvas, isNot(x.surface), reason: '$name canvas vs surface');
        expect(
          x.surface,
          isNot(x.surfaceRaised),
          reason: '$name surface vs raised',
        );
      });

      test('$name — the two bubbles differ', () {
        // Own and peer bubbles at the same colour remove the one cue that
        // tells you at a glance who said what.
        expect(
          x.ownBubble,
          isNot(x.peerBubble),
          reason: '$name own vs peer bubble',
        );
      });

      test('$name — a separator is visible but not loud', () {
        // A separator that matches the surface is invisible; one that reads as
        // text is worse than no rule at all.
        final vsCanvas = _contrast(x.separator, x.canvas);
        expect(vsCanvas, greaterThan(1.05), reason: '$name too invisible');
        expect(vsCanvas, lessThan(3.0), reason: '$name too loud');
      });
    }
  });

  group('dark palette specifics', () {
    final x = XColors.dark(_scheme(Brightness.dark));

    test('the canvas is not pure black', () {
      // Pure #000 on an OLED smears glyph edges and makes a bubble shadow
      // undetectable, so the bubble loses its separation from the page.
      expect(x.canvas, isNot(const Color(0xFF000000)));
      // ...but it must still be dark, or it is not a dark theme.
      expect(_luminance(x.canvas), lessThan(0.02));
    });

    test('the shadow is darker than the canvas so it can do its job', () {
      expect(_luminance(x.shadow), lessThan(_luminance(x.canvas)));
    });

    test('the own-bubble colour is tinted toward the accent', () {
      // A grey own-bubble on a dark page reads as "incoming, but darker",
      // which is exactly backwards.
      expect(x.ownBubble.b, greaterThan(x.ownBubble.r));
    });
  });

  group('copyWith and lerp keep the palette intact', () {
    test('copyWith changes only what it is given', () {
      final x = XColors.dark(_scheme(Brightness.dark));
      final changed = x.copyWith(danger: const Color(0xFFFF0000));
      expect(changed.danger, const Color(0xFFFF0000));
      expect(changed.canvas, x.canvas);
      expect(changed.foregrounds.keys, x.foregrounds.keys);
    });

    test('lerp is total — no role is left behind', () {
      // A lerp that dropped a role would compile fine and produce an
      // invisible colour at t = 0.5 in production only.
      final a = XColors.dark(_scheme(Brightness.dark));
      final b = XColors.light(_scheme(Brightness.light));
      final mid = a.lerp(b, 0.5);
      for (final key in a.foregrounds.keys) {
        expect(mid.foregrounds[key], isNotNull, reason: key);
      }
      expect(mid.canvas, isNot(a.canvas));
      expect(mid.canvas, isNot(b.canvas));
    });
  });

  group('the spacing scale is a scale', () {
    test('every step is a multiple of the unit', () {
      const steps = [
        XDimens.xs,
        XDimens.sm,
        XDimens.md,
        XDimens.lg,
        XDimens.xl,
        XDimens.xxl,
      ];
      for (final step in steps) {
        expect(step % XDimens.unit, 0, reason: '$step is off-grid');
      }
    });

    test('and strictly increasing', () {
      // A scale that is not monotonic means one of the two names is lying.
      const steps = [
        XDimens.xs,
        XDimens.sm,
        XDimens.md,
        XDimens.lg,
        XDimens.xl,
        XDimens.xxl,
      ];
      for (var i = 1; i < steps.length; i++) {
        expect(steps[i], greaterThan(steps[i - 1]));
      }
    });

    test('type sizes decrease from display to caption', () {
      // Descending, not ascending: display is the largest and caption the
      // smallest. The assertion was originally written the other way round,
      // which would have passed for any scale that happened to be increasing —
      // including one whose names were shuffled.
      const type = [
        XDimens.typeDisplay,
        XDimens.typeTitle,
        XDimens.typeHeadline,
        XDimens.typeBody,
        XDimens.typeLabel,
        XDimens.typeCaption,
      ];
      for (var i = 1; i < type.length; i++) {
        expect(
          type[i],
          lessThan(type[i - 1]),
          reason: 'step $i is not smaller than the one before it',
        );
      }
    });

    test('caption is still legible, not merely smaller', () {
      // Below about 11sp glyphs stop being distinguishable on a low-density
      // panel; below 10 they do not survive a screenshot.
      expect(XDimens.typeCaption, greaterThanOrEqualTo(11));
      expect(XDimens.typeBody, greaterThanOrEqualTo(15));
    });
  });
}
