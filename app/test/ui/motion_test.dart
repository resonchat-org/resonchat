// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Motion tokens and shared widgets. Page routes use Material's default Zoom.

import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:resonchat/ui/motion.dart';
import 'package:resonchat/ui/theme.dart';

void main() {
  test('routes keep Material defaults (no custom pageTransitionsTheme)', () {
    final theme = AppThemeTokens.light();
    final stock = ThemeData(useMaterial3: true).pageTransitionsTheme;
    expect(theme.pageTransitionsTheme.builders, stock.builders);
  });

  testWidgets('collapse keeps content at its natural cross-axis width', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.centerRight,
            child: SizedBox(
              width: 120,
              child: MotionCollapse(
                visible: true,
                child: Text('short translation'),
              ),
            ),
          ),
        ),
      ),
    );

    final size = tester.widget<SizeTransition>(find.byType(SizeTransition));
    expect(
      size.fixedCrossAxisSizeFactor,
      1.0,
      reason: 'a vertical collapse must not stretch the child to full width',
    );
  });
}
