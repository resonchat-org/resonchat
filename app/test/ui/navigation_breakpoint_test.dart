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
  Future<bool> railAt(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late bool rail;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            rail = usesNavigationRail(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    return rail;
  }

  group('navigation breakpoint', () {
    testWidgets('a tall desktop window uses the side rail', (tester) async {
      // The reported layout: wide enough for the rail, taller than it is wide.
      expect(await railAt(tester, const Size(886, 965)), isTrue);
    });

    testWidgets('a phone-width window keeps the floating dock', (tester) async {
      expect(await railAt(tester, const Size(480, 900)), isFalse);
    });

    testWidgets('phone landscape also gets the rail', (tester) async {
      expect(await railAt(tester, const Size(640, 360)), isTrue);
    });

    testWidgets('the breakpoint is inclusive', (tester) async {
      expect(
        await railAt(tester, const Size(kNavigationRailMinWidth, 800)),
        isTrue,
      );
      expect(
        await railAt(tester, const Size(kNavigationRailMinWidth - 1, 800)),
        isFalse,
      );
    });
  });
}
