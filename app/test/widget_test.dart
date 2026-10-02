// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The encryption page must not overstate the protection in force, and the
// verification checklist must require both sides (docs/09 §1.1).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonchat/omemo/protocol.dart';
import 'package:resonchat/ui/theme.dart';

Widget wrap(Widget child) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppThemeTokens.light(),
      // A Scaffold supplies the Material ancestor that InkWell-based widgets
      // (such as EncBadge) require.
      home: Scaffold(body: Center(child: child)),
    );

void main() {
  group('EncBadge', () {
    testWidgets('shows the track and a closed lock when encrypted',
        (tester) async {
      await tester.pumpWidget(
        wrap(const EncBadge(label: 'PQ', locked: true)),
      );
      expect(find.text('PQ'), findsOneWidget);
      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
    });

    testWidgets('shows an open lock when unencrypted', (tester) async {
      await tester.pumpWidget(
        wrap(const EncBadge(label: 'Unencrypted', locked: false)),
      );
      expect(find.byIcon(Icons.lock_open_outlined), findsOneWidget);
    });
  });

  group('theme', () {
    test('light and dark differ on every surface token', () {
      const light = TgColors.light();
      const dark = TgColors.dark();
      expect(light.pageBackground, isNot(dark.pageBackground));
      expect(light.ownBubble, isNot(dark.ownBubble));
      expect(light.peerBubble, isNot(dark.peerBubble));
      expect(light.textPrimary, isNot(dark.textPrimary));
    });

    test('body text stays readable against its bubble in both themes', () {
      double luminance(Color c) {
        double f(double v) => v <= 0.03928
            ? v / 12.92
            : _pow((v + 0.055) / 1.055, 2.4);
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

  group('track labels', () {
    test('each mode maps to a distinct, honest label', () {
      final labels = {
        for (final m in EncMode.values) m: encModeLabel(m),
      };
      expect(labels[EncMode.none], 'Unencrypted');
      expect(labels[EncMode.standardOmemo], 'OMEMO');
      expect(labels[EncMode.pqOmemo], 'PQ');
      expect(labels.values.toSet().length, 3);
    });
  });
}

double _pow(double base, double exp) {
  var result = 1.0;
  var b = base;
  var e = exp.toInt();
  while (e > 0) {
    if (e.isOdd) result *= b;
    b *= b;
    e >>= 1;
  }
  if (exp - exp.toInt() > 0) result *= b;
  return result;
}