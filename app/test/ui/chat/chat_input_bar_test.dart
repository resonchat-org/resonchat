// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The composer mirrors Telegram's `ChatActivityEnterView` inside its floating
// "input island" (docs/05 §3.1), so these lock the geometry both layers use:
// the 7dp/9dp card with 22dp corners, the 44dp slots, the 29dp smiley on its
// 42×38 tile, the microphone of the empty right-hand slot, and the 38dp send
// circle.

import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:resonchat/l10n/l10n.dart';
import 'package:resonchat/ui/chat/chat_input_bar.dart';
import 'package:resonchat/ui/chat/glass_panel.dart';
import 'package:resonchat/ui/theme.dart';

/// `AppColors.light()` (day) accent — the fill of the send circle.
final _accent = const AppColors.light().accent;

/// The island's glass fill: the message panel, just short of opaque.
final _glass = const AppColors.light().pageBackground.withValues(alpha: 0.86);

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

/// The closest ancestor [Container] of [of] — the tile behind a glyph.
Finder _containerAround(Finder of) =>
    find.ancestor(of: of, matching: find.byType(Container)).first;

void main() {
  testWidgets('is a 22dp island: 7dp in from the sides, 9dp under it', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(bar()));

    // `ChatActivity.java:8431` puts the bar inside the island bubble with 7dp
    // of side margin; `INPUT_BUBBLE_BOTTOM` = 9dp keeps it off the inset.
    final outer = tester.widget<Padding>(
      find
          .descendant(
            of: find.byType(ChatInputBar),
            matching: find.byType(Padding),
          )
          .first,
    );
    expect(outer.padding, const EdgeInsets.fromLTRB(7, 0, 7, 9));

    // `INPUT_BUBBLE_RADIUS` = 22, glass-filled, over a blur of the transcript
    // (`ChatInputViewsContainer.java:27`, `:79`-`:88`).
    final card = tester.widget<GlassPanel>(find.byType(GlassPanel));
    expect(card.radius, 22);
    expect(card.fill, _glass);
    expect(
      find.descendant(
        of: find.byType(GlassPanel),
        matching: find.byType(BackdropFilter),
      ),
      findsOneWidget,
    );

    // Every icon slot is still `DEFAULT_HEIGHT` = 44dp.
    final slot = find
        .ancestor(of: find.byIcon(Icons.mic), matching: find.byType(SizedBox))
        .first;
    expect(tester.getSize(slot), const Size(44, 44));
  });

  testWidgets('smiley is 29dp on a 42×38 tile, the paperclip a 24dp glyph', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(bar()));

    // `emojiButton`: 44dp with `dp(7.5)` of padding.
    expect(
      tester.getSize(find.byIcon(Icons.emoji_emotions_outlined)),
      const Size(29, 29),
    );
    // `createInsetRoundRectDrawable(key_listSelector, dp(19), dp(1), dp(3))`:
    // the tile is 1dp off the sides and 3dp off the top and bottom.
    final tile = _containerAround(find.byIcon(Icons.emoji_emotions_outlined));
    expect(tester.getSize(tile), const Size(42, 38));
    final decoration =
        tester.widget<Container>(tile).decoration! as BoxDecoration;
    expect(
      decoration.color,
      const AppColors.light().textPrimary.withValues(alpha: 0.06),
    );
    expect(
      decoration.borderRadius,
      BorderRadius.circular(19),
      reason: '19dp radius is what rounds the reference tile',
    );

    // `msg_input_attach2`.
    expect(tester.getSize(find.byIcon(Icons.attach_file)), const Size(24, 24));
  });

  testWidgets('empty field: the right slot is a bare microphone, no circle', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(bar()));

    expect(find.byIcon(Icons.mic), findsOneWidget);
    expect(find.byIcon(Icons.send), findsNothing);
    expect(find.byIcon(Icons.more_vert), findsNothing);
    expect(tester.getSize(find.byIcon(Icons.mic)), const Size(24, 24));

    // The record button is a plain glyph, so the slot carries no fill.
    expect(
      find.ancestor(
        of: find.byIcon(Icons.mic),
        matching: find.byType(Container),
      ),
      findsNothing,
    );
  });

  testWidgets(
    'text swaps the microphone for the paper plane in the same slot',
    (tester) async {
      final controller = TextEditingController();
      await tester.pumpWidget(wrap(bar(controller: controller)));

      controller.text = 'hello';
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.send), findsOneWidget);
      expect(find.byIcon(Icons.mic), findsNothing);
      final circle = find
          .ancestor(
            of: find.byIcon(Icons.send),
            matching: find.byType(Material),
          )
          .first;
      expect(tester.getSize(circle), const Size(38, 38));
      expect(tester.widget<Material>(circle).color, _accent);
    },
  );

  testWidgets('no upload slot: the microphone greys out instead of vanishing', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(bar(attachEnabled: false)));

    final icon = tester.widget<Icon>(find.byIcon(Icons.mic));
    expect(
      icon.color,
      const AppColors.light().textSecondary.withValues(alpha: 0.5),
    );
    expect(
      find.byIcon(Icons.mic),
      findsOneWidget,
      reason: 'the record slot greys out rather than dropping out',
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
