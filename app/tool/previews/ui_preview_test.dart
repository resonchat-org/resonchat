// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Renders the Telegram-like UI to PNGs so the layout can be reviewed
// without a device (docs/05). Uses the golden-file mechanism purely as a
// renderer: we write the images out and never compare them, so this
// cannot fail on a visual diff.
//
//   flutter test test/ui_preview_test.dart
//   → test/previews/*.png
//
// Keep `test/previews/` out of git; regenerate instead of reviewing diffs.

// Renders UI previews to PNGs for design review. Lives outside test/ so
// `flutter test` never picks it up — it has no committed baseline to diff
// against, by design.
//
//   flutter test --update-goldens tool/previews/ui_preview_test.dart
//
// Output: build/ui-previews/*.png

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonchat/ui/message_bubble.dart';
import 'package:resonchat/ui/theme.dart';

const _previewDir = 'build/ui-previews';

void main() {
  setUpAll(() {
    final dir = Directory(_previewDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);
  });

  // The test binding forces the Ahem font (every glyph a filled box), so
  // text is unreadable in these previews; spacing, alignment, bubble tails
  // and ticks are still reviewable. For real text use a device or the
  // desktop build. We do not load a font here because FontLoader
  // deadlocks `flutter test` on Linux.
  final previewFont = AppThemeTokens.fontFamily;

  Widget lightSample() => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppThemeTokens.light(),
        builder: (context, child) => DefaultTextStyle.merge(
          style: TextStyle(fontFamily: previewFont),
          child: child!,
        ),
        home: Scaffold(
          body: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              DateSeparator(date: DateTime(2026, 10, 2)),
              MessageBubble(
                text: 'Hey, are we still on for tonight?',
                time: DateTime(2026, 10, 2, 19, 4),
                side: BubbleSide.incoming,
                senderName: 'Alice',
              ),
              MessageBubble(
                text: 'Yes. I finished the PQ handshake.',
                time: DateTime(2026, 10, 2, 19, 6),
                side: BubbleSide.outgoing,
                delivered: true,
              ),
              MessageBubble(
                text: 'Sent.',
                time: DateTime(2026, 10, 2, 19, 6),
                side: BubbleSide.outgoing,
              ),
              MessageBubble(
                text: 'Mirrored from my laptop.',
                time: DateTime(2026, 10, 2, 19, 7),
                side: BubbleSide.outgoing,
                delivered: true,
              ),
              UnreadDivider(),
              MessageBubble(
                text: 'That one could not be decrypted.',
                time: DateTime(2026, 10, 2, 19, 8),
                side: BubbleSide.incoming,
              ),
            ],
          ),
        ),
      );

  Widget darkSample() => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppThemeTokens.dark(),
        builder: (context, child) => DefaultTextStyle.merge(
          style: TextStyle(fontFamily: previewFont),
          child: child!,
        ),
        home: Scaffold(
          body: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              DateSeparator(date: DateTime(2026, 10, 2)),
              MessageBubble(
                text: 'Dark theme check.',
                time: DateTime(2026, 10, 2, 19, 4),
                side: BubbleSide.incoming,
                senderName: 'Alice',
              ),
              MessageBubble(
                text: 'Looks right.',
                time: DateTime(2026, 10, 2, 19, 6),
                side: BubbleSide.outgoing,
                delivered: true,
              ),
            ],
          ),
        ),
      );

  testWidgets('render light bubbles', (tester) async {
    tester.view.physicalSize = const Size(420, 620);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(lightSample());
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('$_previewDir/bubbles_light.png'),
    );
  });

  testWidgets('render dark bubbles', (tester) async {
    tester.view.physicalSize = const Size(420, 260);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(darkSample());
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('$_previewDir/bubbles_dark.png'),
    );
  });
}