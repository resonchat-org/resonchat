// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The message menu is a vertical list with the reaction row on top, not a grid
// of two-line cells. The trailing arrow swaps the action list for a full emoji
// picker; picking there is reported as `fromMore` so the caller can promote it
// into the front row.

import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:resonchat/l10n/l10n.dart';
import 'package:resonchat/ui/chat/message_actions.dart';
import 'package:resonchat/ui/theme.dart';
import 'package:resonchat/xmpp/chat/reactions.dart';

Widget wrap(Widget child) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: AppThemeTokens.light(),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  locale: const Locale('zh'),
  home: child,
);

MessageActions allActions() => MessageActions.for_(
  mine: true,
  retracted: false,
  decrypted: true,
  addressable: true,
  pinned: false,
);

/// Pumps a page with a button that opens the menu and records its result.
Widget host(
  void Function(MessageMenuResult? result) onResult, {
  List<String>? quickReactions,
}) {
  return wrap(
    Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: ElevatedButton(
            onPressed: () async {
              final result = await showMessageMenu(
                context,
                actions: allActions(),
                trackIsPlaintext: false,
                anchor: const Rect.fromLTWH(200, 400, 220, 60),
                quickReactions: quickReactions ?? kQuickReactions,
              );
              onResult(result);
            },
            child: const Text('打开'),
          ),
        ),
      ),
    ),
  );
}

Future<void> openPicker(WidgetTester tester) async {
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
  await tester.tap(find.byIcon(Icons.keyboard_arrow_down));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('quick reactions live in the menu and return the emoji', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    MessageMenuResult? result;
    await tester.pumpWidget(host((picked) => result = picked));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    // The row and the action list are in the same card, and every default is
    // a coloured glyph (the heart slot is 💗, not text-style ❤).
    expect(find.text('👍'), findsOneWidget);
    expect(find.text('💗'), findsOneWidget);
    expect(find.text('❤'), findsNothing);
    expect(find.text('回复'), findsOneWidget);
    expect(find.text('复制文本'), findsOneWidget);
    expect(find.byType(GridView), findsNothing);
    expect(
      tester.widget<Text>(find.text('👍')).style?.fontFamily,
      'Noto Color Emoji',
    );

    await tester.tap(find.text('👍'));
    await tester.pumpAndSettle();

    expect(result, isA<MessageMenuReaction>());
    expect((result! as MessageMenuReaction).emoji, '👍');
    expect((result! as MessageMenuReaction).fromMore, isFalse);
    // Choosing an emoji closes the menu.
    expect(find.text('回复'), findsNothing);
  });

  testWidgets('the list returns the chosen action', (tester) async {
    tester.view.physicalSize = const Size(1000, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    MessageMenuResult? result;
    await tester.pumpWidget(host((picked) => result = picked));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('复制文本'));
    await tester.pumpAndSettle();

    expect(result, isA<MessageMenuAction>());
    expect((result! as MessageMenuAction).action, MessageAction.copy);
  });

  testWidgets('the arrow opens a large colour picker with a category bar', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host((_) {}));
    await openPicker(tester);

    // The picker replaces the commands rather than appending a row to them.
    expect(find.text('回复'), findsNothing);
    expect(find.text('复制文本'), findsNothing);
    expect(find.byIcon(Icons.arrow_back), findsOneWidget);
    expect(find.text('笑脸和人物'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);

    // Seven large emoji per row, with a visible scrollbar so the rest of the
    // category is obviously reachable.
    final grid = tester.widget<GridView>(find.byType(GridView));
    final delegate =
        grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
    expect(delegate.crossAxisCount, 7);
    expect(
      tester.widget<Scrollbar>(find.byType(Scrollbar)).thumbVisibility,
      isTrue,
    );

    // The glyph itself asks for the colour emoji family, not the system's
    // monochrome symbol fallback.
    final glyph = tester.widget<Text>(find.text('😀'));
    expect(glyph.style?.fontFamily, 'Noto Color Emoji');
    expect(glyph.style?.fontSize, 30);

    // Category tabs switch the title and the grid.
    await tester.tap(find.byTooltip('动物和自然'));
    await tester.pumpAndSettle();
    expect(find.text('动物和自然'), findsOneWidget);
    expect(find.text('🦄'), findsOneWidget);

    await tester.tap(find.byTooltip('食物和饮料'));
    await tester.pumpAndSettle();
    expect(find.text('食物和饮料'), findsOneWidget);
    expect(find.text('🦄'), findsNothing);
  });

  testWidgets('picking from the picker is marked as a promotion', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    MessageMenuResult? result;
    await tester.pumpWidget(host((picked) => result = picked));
    await openPicker(tester);

    await tester.tap(find.byTooltip('动物和自然'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('🦄'));
    await tester.pumpAndSettle();

    expect(result, isA<MessageMenuReaction>());
    expect((result! as MessageMenuReaction).emoji, '🦄');
    expect((result! as MessageMenuReaction).fromMore, isTrue);
    expect(find.byType(GridView), findsNothing);
  });

  testWidgets('the back arrow returns to the action list', (tester) async {
    tester.view.physicalSize = const Size(1000, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host((_) {}));
    await openPicker(tester);

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();

    expect(find.text('回复'), findsOneWidget);
    expect(find.byType(GridView), findsNothing);
    expect(find.text('笑脸和人物'), findsNothing);
  });

  test('body text does not use the wide emoji numerals', () {
    // Noto Color Emoji also covers ASCII digits, with advances over one em.
    // Putting it on body text turns "21:03" into "2 1 : 0 3"; only emoji-only
    // widgets may name that family.
    final style = AppThemeTokens.light().textTheme.bodyMedium!;
    expect(style.fontFamily, isNot('Noto Color Emoji'));
    expect(
      style.fontFamilyFallback ?? const <String>[],
      isNot(contains('Noto Color Emoji')),
    );
  });
}
