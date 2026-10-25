// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The menu is anchored to the bubble, not to the full-width row. A row anchor
// puts the card in the middle of the pane, far from a right-hand message.
// Opening the palette also replaces the action list instead of appending to it.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:resonchat/l10n/l10n.dart';
import 'package:resonchat/ui/chat/message_actions.dart';
import 'package:resonchat/ui/chat/message_bubble.dart';
import 'package:resonchat/ui/theme.dart';

MessageActions actions() => MessageActions.for_(
  mine: true,
  retracted: false,
  decrypted: true,
  addressable: true,
  pinned: false,
);

Widget app() => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: AppThemeTokens.light(),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  locale: const Locale('zh'),
  home: Builder(
    builder: (context) => Scaffold(
      body: SafeArea(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            MessageBubble(
              text: '这是一条被右键的消息',
              time: DateTime(2026, 10, 24, 9, 40),
              side: BubbleSide.outgoing,
              mine: true,
              onMenu: (anchor) => showMessageMenu(
                context,
                actions: actions(),
                trackIsPlaintext: false,
                anchor: anchor,
              ),
            ),
            const SizedBox(height: 120),
          ],
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('the menu opens beside the bubble, not mid-pane', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(app());

    await tester.tapAt(
      tester.getCenter(find.text('这是一条被右键的消息')),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();

    expect(find.text('回复'), findsOneWidget);
    final bubble = tester.getRect(find.text('这是一条被右键的消息'));
    final card = tester.getRect(find.byType(SingleChildScrollView));
    // The row spans 1200 and its centre is 600. Anchoring to it would put the
    // card ~450 from a right-hand bubble.
    expect((card.center.dx - bubble.center.dx).abs(), lessThan(300));

    await tester.tap(find.byIcon(Icons.keyboard_arrow_down));
    await tester.pumpAndSettle();

    // The picker replaces the commands while it is open.
    expect(find.text('回复'), findsNothing);
    expect(find.byIcon(Icons.arrow_back), findsOneWidget);
    expect(find.text('笑脸和人物'), findsOneWidget);
    expect(find.byType(GridView), findsOneWidget);
  });
}
