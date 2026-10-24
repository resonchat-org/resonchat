// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Navigation chrome follows the window *width*, not its orientation.
//
// A 886×965 Linux window is portrait by aspect ratio, and deciding on
// orientation put the phone's floating dock over a desktop conversation: it
// covered the composer while 886 px of width sat unused. These lock the
// breakpoint so the rail wins on desktop-shaped windows whatever their height.

import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:resonchat/ui/column_mode.dart';

void main() {
  Future<(bool rail, bool column)> wideAt(
    WidgetTester tester,
    Size size,
  ) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late bool rail;
    late bool column;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            rail = usesNavigationRail(context);
            column = isColumnMode(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    return (rail, column);
  }

  group('navigation breakpoint', () {
    testWidgets('a tall desktop window uses the side rail', (tester) async {
      // The reported layout: wide enough for the rail, taller than it is wide.
      final (rail, column) = await wideAt(tester, const Size(886, 965));
      expect(rail, isTrue);
      expect(column, isTrue);
    });

    testWidgets('a phone-width window keeps the floating dock', (tester) async {
      final (rail, column) = await wideAt(tester, const Size(480, 900));
      expect(rail, isFalse);
      expect(column, isFalse);
    });

    testWidgets('phone landscape also gets the rail and split', (tester) async {
      final (rail, column) = await wideAt(tester, const Size(640, 360));
      expect(rail, isTrue);
      expect(column, isTrue);
    });

    testWidgets('rail and column share one inclusive 600 gate', (tester) async {
      final at = await wideAt(tester, const Size(kNavigationRailMinWidth, 800));
      expect(at.$1, isTrue);
      expect(at.$2, isTrue);
      final below = await wideAt(
        tester,
        const Size(kNavigationRailMinWidth - 1, 800),
      );
      expect(below.$1, isFalse);
      expect(below.$2, isFalse);
      // Former 600–720 band is gone: 650 is already master/detail.
      final mid = await wideAt(tester, const Size(650, 800));
      expect(mid.$1, isTrue);
      expect(mid.$2, isTrue);
    });
  });
}
