// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Motion tokens and the two shared widgets that carry them: the page
// transition and the state-preserving tab stack. These are regression locks,
// not pixel tests — the useful failure is "the exit half of a tab switch
// stopped ticking again".

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:resonchat/ui/motion.dart';
import 'package:resonchat/ui/theme.dart';

void main() {
  test('desktop uses the shared page transition', () {
    final theme = AppThemeTokens.light();
    for (final platform in [
      TargetPlatform.linux,
      TargetPlatform.windows,
      TargetPlatform.fuchsia,
    ]) {
      expect(
        theme.pageTransitionsTheme.builders[platform],
        isA<ResonMotionPageTransitionsBuilder>(),
        reason: '$platform should use the shared slide/fade',
      );
    }
  });

  test('mobile keeps the platform back gesture', () {
    final theme = AppThemeTokens.light();
    expect(
      theme.pageTransitionsTheme.builders[TargetPlatform.iOS],
      isA<CupertinoPageTransitionsBuilder>(),
    );
    expect(
      theme.pageTransitionsTheme.builders[TargetPlatform.macOS],
      isA<CupertinoPageTransitionsBuilder>(),
    );
    expect(
      theme.pageTransitionsTheme.builders[TargetPlatform.android],
      isA<PredictiveBackPageTransitionsBuilder>(),
    );
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

  testWidgets('tab stack cross-fades and keeps every page mounted', (
    tester,
  ) async {
    var index = 0;
    late StateSetter setIndex;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            setIndex = setState;
            return MotionTabStack(
              index: index,
              children: const [
                ColoredBox(color: Colors.red, key: ValueKey('first')),
                ColoredBox(color: Colors.blue, key: ValueKey('second')),
              ],
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    Iterable<FadeTransition> fades() => tester.widgetList<FadeTransition>(
      find.descendant(
        of: find.byType(MotionTabStack),
        matching: find.byType(FadeTransition),
      ),
    );

    expect(fades().map((f) => f.opacity.value), containsAll(<double>[0, 1]));

    setIndex(() => index = 1);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 110));

    // Both layers are mid-fade. If the leaving page's ticker were disabled by
    // TickerMode, its opacity would still be 1 here and the two pages would
    // remain stacked after the switch.
    final midway = fades().map((f) => f.opacity.value).toList();
    expect(midway.where((v) => v > 0 && v < 1).length, 2);

    await tester.pumpAndSettle();
    expect(fades().map((f) => f.opacity.value), containsAll(<double>[0, 1]));
    expect(find.byKey(const ValueKey('first')), findsOneWidget);
    expect(find.byKey(const ValueKey('second')), findsOneWidget);
  });
}
