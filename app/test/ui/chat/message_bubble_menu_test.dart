// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The message menu opens on long-press (touch) and on right-click (desktop).

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:resonchat/l10n/l10n.dart';
import 'package:resonchat/ui/chat/message_bubble.dart';
import 'package:resonchat/ui/theme.dart';

Widget wrap(Widget child) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: AppThemeTokens.light(),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  locale: const Locale('zh'),
  home: Scaffold(body: Center(child: child)),
);

void main() {
  testWidgets('right-click opens the menu on a desktop pointer', (
    tester,
  ) async {
    Rect? anchor;
    await tester.pumpWidget(
      wrap(
        MessageBubble(
          text: '你好',
          time: DateTime(2026, 10, 24),
          side: BubbleSide.incoming,
          onMenu: (rect) => anchor = rect,
        ),
      ),
    );

    await tester.tapAt(
      tester.getCenter(find.text('你好')),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await tester.pump();

    expect(anchor, isNotNull);
    // The menu anchors to the bubble, not the full-width row: a row rect would
    // span the whole test surface and put the card in the middle of the pane.
    expect(anchor!.width, lessThan(300));
    expect(anchor!.contains(tester.getCenter(find.text('你好'))), isTrue);
  });

  testWidgets('long-press still opens the menu on touch', (tester) async {
    Rect? anchor;
    await tester.pumpWidget(
      wrap(
        MessageBubble(
          text: '你好',
          time: DateTime(2026, 10, 24),
          side: BubbleSide.incoming,
          onMenu: (rect) => anchor = rect,
        ),
      ),
    );

    await tester.longPress(find.text('你好'));
    await tester.pump();

    expect(anchor, isNotNull);
  });
}
