// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonchat/ui/theme.dart';

Widget wrap(Widget child) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppThemeTokens.light(),
      home: Scaffold(body: child),
    );

void main() {
  group('EncBadge', () {
    testWidgets('shows the track label with a closed lock when encrypted',
        (tester) async {
      await tester.pumpWidget(
        wrap(const EncBadge(label: 'PQ', locked: true)),
      );
      expect(find.text('PQ'), findsOneWidget);
      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
      expect(find.byIcon(Icons.lock_open_outlined), findsNothing);
    });

    testWidgets('shows an open lock when unencrypted', (tester) async {
      await tester.pumpWidget(
        wrap(const EncBadge(label: 'Unencrypted', locked: false)),
      );
      expect(find.byIcon(Icons.lock_open_outlined), findsOneWidget);
      expect(find.text('Unencrypted'), findsOneWidget);
    });

    testWidgets('is tappable when a callback is given', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        wrap(EncBadge(label: 'OMEMO', locked: true, onTap: () => taps++)),
      );
      await tester.tap(find.text('OMEMO'));
      await tester.pump();
      expect(taps, 1);
    });
  });

  group('TgColors', () {
    test('light and dark differ on every surface token', () {
      const light = TgColors.light();
      const dark = TgColors.dark();
      expect(light.pageBackground, isNot(dark.pageBackground));
      expect(light.ownBubble, isNot(dark.ownBubble));
      expect(light.peerBubble, isNot(dark.peerBubble));
      expect(light.barBackground, isNot(dark.barBackground));
      expect(light.textPrimary, isNot(dark.textPrimary));
    });

    test('text stays legible against its bubble in both themes', () {
      // Contrast ratio (WCAG) for the sampled Telegram colours.
      double luminance(Color c) {
        double f(double v) => v <= 0.03928
            ? v / 12.92
            : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
        return f(c.r) * 0.2126 + f(c.g) * 0.7152 + f(c.b) * 0.0722;
      }

      double ratio(Color a, Color b) {
        final la = luminance(a), lb = luminance(b);
        final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
        return (hi + 0.05) / (lo + 0.05);
      }

      const light = TgColors.light();
      expect(ratio(light.textPrimary, light.ownBubble), greaterThan(7.0));
      expect(ratio(light.textPrimary, light.peerBubble), greaterThan(7.0));

      const dark = TgColors.dark();
      expect(ratio(dark.textPrimary, dark.ownBubble), greaterThan(4.5));
      expect(ratio(dark.textPrimary, dark.peerBubble), greaterThan(4.5));
    });
  });
}