// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Desktop split: the chat list and the conversation are cards on a tinted
// canvas with a gutter, not one surface cut by a 1 px divider.

import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:resonchat/l10n/l10n.dart';
import 'package:resonchat/ui/desktop_surface.dart';
import 'package:resonchat/ui/home/landscape_rail.dart';
import 'package:resonchat/ui/theme.dart';
import 'package:resonchat/ui/two_column_layout.dart';

Widget wrap(Widget child) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: AppThemeTokens.light(),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  locale: const Locale('zh'),
  home: child,
);

void main() {
  testWidgets('the two panes are separate rounded cards', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      wrap(
        Scaffold(
          body: TwoColumnLayout(
            mainView: const ColoredBox(color: Colors.white),
            sideView: const ColoredBox(color: Colors.blueGrey),
          ),
        ),
      ),
    );

    expect(find.byType(VerticalDivider), findsNothing);
    expect(find.byType(DesktopPane), findsNWidgets(2));

    final gutter = tester.widget<SizedBox>(
      find.byWidgetPredicate(
        (widget) => widget is SizedBox && widget.width == kDesktopGutter,
      ),
    );
    expect(gutter.width, kDesktopGutter);

    final radius = BorderRadius.circular(kDesktopPaneRadius);
    final rounded = tester
        .widgetList<ClipRRect>(find.byType(ClipRRect))
        .where((clip) => clip.borderRadius == radius);
    expect(rounded.length, greaterThanOrEqualTo(2));
  });

  testWidgets('the desktop shell has no hard divider beside the rail', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        child: wrap(
          LandscapeFrame(
            navigatorKey: GlobalKey<NavigatorState>(),
            child: const ColoredBox(color: Colors.white),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(VerticalDivider), findsNothing);
    expect(find.byType(DesktopPane), findsOneWidget);
  });

  testWidgets('the canvas is tinted in light and dark themes', (tester) async {
    for (final brightness in Brightness.values) {
      late Color canvas;
      late Color page;
      await tester.pumpWidget(
        MaterialApp(
          theme: brightness == Brightness.light
              ? AppThemeTokens.light()
              : AppThemeTokens.dark(),
          home: Builder(
            builder: (context) {
              canvas = desktopCanvasOf(context);
              page = context.tg.pageBackground;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(canvas, isNot(page));
    }
  });
}
