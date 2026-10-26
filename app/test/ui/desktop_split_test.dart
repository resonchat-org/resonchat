// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Desktop split: conversation nested inset in the list tray (left-edge
// radius + border), not dual cards and not stretched flush.

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
  testWidgets('the conversation is nested inset in the list tray', (
    tester,
  ) async {
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
    expect(find.byType(DesktopChatPane), findsOneWidget);

    final radius = BorderRadius.circular(kDesktopChatRadius);
    expect(
      tester
          .widgetList<Container>(find.byType(Container))
          .where(
            (c) =>
                c.clipBehavior == Clip.antiAlias &&
                c.decoration is BoxDecoration &&
                (c.decoration! as BoxDecoration).borderRadius == radius,
          ),
      isNotEmpty,
    );

    expect(
      tester
          .widgetList<Padding>(find.byType(Padding))
          .where(
            (p) =>
                p.padding ==
                const EdgeInsets.only(
                  top: kDesktopChatInset,
                  right: kDesktopChatInset,
                  bottom: kDesktopChatInset,
                ),
          ),
      isNotEmpty,
    );
  });

  testWidgets('the main content keeps a left-edge radius beside the rail', (
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
    expect(find.byType(DesktopChatPane), findsNothing);

    const radius = BorderRadius.only(
      topLeft: Radius.circular(kDesktopContentRadius),
      bottomLeft: Radius.circular(kDesktopContentRadius),
    );
    expect(
      tester
          .widgetList<ClipRRect>(find.byType(ClipRRect))
          .where((c) => c.borderRadius == radius),
      isNotEmpty,
    );
  });

  testWidgets('the list tray is deeper than the page background', (
    tester,
  ) async {
    for (final brightness in Brightness.values) {
      late Color tray;
      late Color page;
      await tester.pumpWidget(
        MaterialApp(
          theme: brightness == Brightness.light
              ? AppThemeTokens.light()
              : AppThemeTokens.dark(),
          home: Builder(
            builder: (context) {
              tray = desktopListTrayOf(context);
              page = context.tg.pageBackground;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(tray, isNot(page));
      expect(tray.computeLuminance(), lessThan(page.computeLuminance()));
    }
  });
}
