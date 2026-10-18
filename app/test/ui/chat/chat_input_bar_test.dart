// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The composer mirrors Telegram's `ChatActivityEnterView` (docs/05 §3.1), so
// these lock the geometry the reference uses: 44dp slots, a 24dp glyph, a 29dp
// smiley, the 38dp send circle, and a flat panel instead of a boxed field
// under a divider.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonchat/l10n/l10n.dart';
import 'package:resonchat/ui/chat/chat_input_bar.dart';
import 'package:resonchat/ui/theme.dart';

/// `TgColors.light()` (day) accent — the fill of the send/mic circle.
final _accent = const TgColors.light().accent;

Widget wrap(Widget child) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: AppThemeTokens.light(),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: Column(children: [const Spacer(), child])),
);

ChatInputBar bar({
  TextEditingController? controller,
  VoidCallback? onSend,
  VoidCallback? onAttach,
  VoidCallback? onStickers,
  bool attachEnabled = true,
  bool stickersOpen = false,
}) => ChatInputBar(
  controller: controller ?? TextEditingController(),
  focusNode: FocusNode(),
  onChanged: (_) {},
  onSend: onSend ?? () {},
  onAttach: onAttach ?? () {},
  onVoice: (_) async {},
  onStickers: onStickers ?? () {},
  stickersOpen: stickersOpen,
  attachEnabled: attachEnabled,
);

/// Closest ancestor of [of] that is a [Container] — the circle around a glyph.
Finder _circleAround(Finder of) =>
    find.ancestor(of: of, matching: find.byType(Container)).first;

void main() {
  testWidgets('is a flat 44dp panel: no divider, compose shadow instead', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(bar()));

    // `DEFAULT_HEIGHT` = 44dp for every icon slot. The row only grows past
    // 45dp when the font draws a line taller than 44dp; the reference's
    // container is WRAP_CONTENT for the same reason.
    final slot = find
        .ancestor(of: find.byIcon(Icons.mic), matching: find.byType(SizedBox))
        .first;
    expect(tester.getSize(slot), const Size(44, 44));
    expect(
      tester.getSize(find.byType(ChatInputBar)).height,
      greaterThanOrEqualTo(45),
    );

    final box = tester.widget<DecoratedBox>(
      find
          .descendant(
            of: find.byType(ChatInputBar),
            matching: find.byType(DecoratedBox),
          )
          .first,
    );
    final decoration = box.decoration as BoxDecoration;
    expect(
      decoration.border,
      isNull,
      reason: 'no separator line above the bar',
    );
    expect(decoration.boxShadow, isNotEmpty);
    expect(decoration.color, const TgColors.light().pageBackground);
  });

  testWidgets(
    'smiley is 29dp and the paperclip is a 24dp glyph, in 44dp slots',
    (tester) async {
      await tester.pumpWidget(wrap(bar()));

      // `emojiButton`: 44dp with `dp(7.5)` of padding.
      expect(
        tester.getSize(find.byIcon(Icons.emoji_emotions_outlined)),
        const Size(29, 29),
      );
      // `msg_input_attach2`.
      expect(
        tester.getSize(find.byIcon(Icons.attach_file)),
        const Size(24, 24),
      );
      expect(
        tester.getSize(find.byIcon(Icons.attach_file)).height,
        lessThanOrEqualTo(44),
      );
    },
  );

  testWidgets('empty field: the mic sits in the 38dp filled circle', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(bar()));

    expect(find.byIcon(Icons.mic), findsOneWidget);
    expect(find.byIcon(Icons.send), findsNothing);
    expect(tester.getSize(find.byIcon(Icons.mic)), const Size(24, 24));

    final circle = _circleAround(find.byIcon(Icons.mic));
    expect(tester.getSize(circle), const Size(38, 38));
    expect(
      (tester.widget<Container>(circle).decoration as BoxDecoration).color,
      _accent,
    );
  });

  testWidgets('text swaps the mic for the paper plane in the same circle', (
    tester,
  ) async {
    final controller = TextEditingController();
    await tester.pumpWidget(wrap(bar(controller: controller)));

    controller.text = 'hello';
    await tester.pump();

    expect(find.byIcon(Icons.send), findsOneWidget);
    expect(find.byIcon(Icons.mic), findsNothing);
    expect(
      tester.getSize(
        find
            .ancestor(
              of: find.byIcon(Icons.send),
              matching: find.byType(Material),
            )
            .first,
      ),
      const Size(38, 38),
    );
  });

  testWidgets('no upload slot: the mic degrades to a plain glyph', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(bar(attachEnabled: false)));

    final decoration = tester
        .widget<Container>(_circleAround(find.byIcon(Icons.mic)))
        .decoration;
    expect(
      decoration,
      isNull,
      reason: 'reference draws a bare mic when voice is unavailable',
    );
  });

  testWidgets('open sticker panel turns the smiley into a keyboard glyph', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(bar(stickersOpen: true)));
    expect(find.byIcon(Icons.keyboard_outlined), findsOneWidget);
    expect(find.byIcon(Icons.emoji_emotions_outlined), findsNothing);
  });

  testWidgets('the field is borderless, 18dp, six lines, with the hint', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(bar()));

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.decoration!.border, InputBorder.none);
    expect(field.decoration!.hintText, 'Message');
    expect(field.style!.fontSize, 18);
    expect(field.maxLines, 6);
    expect(field.minLines, 1);
  });

  testWidgets('taps reach send, attach, and the sticker panel', (tester) async {
    var sent = 0, attached = 0, stickers = 0;
    final controller = TextEditingController(text: 'hi');
    await tester.pumpWidget(
      wrap(
        bar(
          controller: controller,
          onSend: () => sent++,
          onAttach: () => attached++,
          onStickers: () => stickers++,
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.send));
    await tester.tap(find.byIcon(Icons.attach_file));
    await tester.tap(find.byIcon(Icons.emoji_emotions_outlined));
    await tester.pump();

    expect(sent, 1);
    expect(attached, 1);
    expect(stickers, 1);
  });

  testWidgets('attach is inert without an upload slot', (tester) async {
    var attached = 0;
    await tester.pumpWidget(
      wrap(bar(attachEnabled: false, onAttach: () => attached++)),
    );

    await tester.tap(find.byIcon(Icons.attach_file));
    await tester.pump();
    expect(attached, 0);
  });
}
