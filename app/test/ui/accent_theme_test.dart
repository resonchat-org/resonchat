// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Outgoing bubbles follow the accent instead of a frozen green: with a violet
// header the old bubbles read as a second theme colour.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:resonchat/ui/accent_theme.dart';
import 'package:resonchat/ui/theme.dart';

double _luminance(Color c) {
  double f(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return f(c.r) * 0.2126 + f(c.g) * 0.7152 + f(c.b) * 0.0722;
}

double _contrast(Color a, Color b) {
  final la = _luminance(a), lb = _luminance(b);
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  test('every accent tints its own bubble', () {
    for (final accent in AccentColor.values) {
      final light = accent.tgColors(Brightness.light);
      final dark = accent.tgColors(Brightness.dark);
      expect(
        light.ownBubble,
        isNot(const AppColors.light().ownBubble),
        reason: '${accent.stored} kept the old green bubble',
      );
      expect(light.ownBubble, isNot(light.peerBubble));
      expect(dark.ownBubble, isNot(dark.peerBubble));
      // A wash of the accent on the page background stays much nearer the
      // page than the accent itself; a solid accent bubble would fail here.
      expect(
        _contrast(light.ownBubble, light.pageBackground),
        lessThan(_contrast(light.accent, light.pageBackground)),
      );
    }
  });

  test('the violet accent no longer produces a green bubble', () {
    final colors = AccentColor.violet.tgColors(Brightness.light);
    // Green means g > r and g > b; the violet wash is blue-dominant instead.
    expect(colors.ownBubble.b, greaterThan(colors.ownBubble.g));
  });

  test('message text keeps its contrast on the tinted bubble', () {
    for (final accent in AccentColor.values) {
      final light = accent.tgColors(Brightness.light);
      final dark = accent.tgColors(Brightness.dark);
      expect(
        _contrast(light.textPrimary, light.ownBubble),
        greaterThan(7.0),
        reason: '${accent.stored} light',
      );
      expect(
        _contrast(dark.textPrimary, dark.ownBubble),
        greaterThan(4.5),
        reason: '${accent.stored} dark',
      );
    }
  });
}
