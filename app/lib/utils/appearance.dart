// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Chat appearance: wallpaper and bubble shape. Pattern tint follows the app
// theme colour.
//
// Appearance is **per conversation**. Patterns are drawn by Flutter (no image
// files, no I/O) so they survive a reinstall identically.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';

/// How chat bubbles are drawn.
enum BubbleStyle {
  /// Telegram's default: fully rounded, tail-free.
  rounded,

  /// Squarer corners, closer to a system message style.
  square,

  /// Rounded on the side away from the sender, square on the side towards it.
  asymmetric,
}

/// The pattern behind a conversation's messages.
enum Wallpaper {
  /// The plain page colour.
  none,

  /// A field of small dots.
  dots,

  /// Widely spaced diagonal hatching.
  diagonal,

  /// Concentric rings from a corner.
  rings,

  /// Vertical stripes.
  stripes,

  /// A soft two-tone vertical wash.
  gradient,
}

/// What one conversation looks like.
class ChatAppearance {
  const ChatAppearance({
    this.wallpaper = Wallpaper.none,
    this.bubble = BubbleStyle.rounded,
  });

  final Wallpaper wallpaper;
  final BubbleStyle bubble;

  /// Wallpaper index, then bubble index.
  String encode() => '${wallpaper.index}${bubble.index}';

  /// Reads [encode]d form, falling back to the default for anything
  /// unrecognised so a bad row cannot make a conversation unopenable.
  static ChatAppearance decode(String? raw) {
    if (raw == null || raw.length < 2) return const ChatAppearance();
    final wallpaper =
        Wallpaper.values.asNameMap()[raw[0]] ??
        (int.tryParse(raw[0]) != null &&
                int.tryParse(raw[0])! < Wallpaper.values.length
            ? Wallpaper.values[int.parse(raw[0])]
            : Wallpaper.none);
    final bubble =
        BubbleStyle.values.asNameMap()[raw[1]] ??
        (int.tryParse(raw[1]) != null &&
                int.tryParse(raw[1])! < BubbleStyle.values.length
            ? BubbleStyle.values[int.parse(raw[1])]
            : BubbleStyle.rounded);
    return ChatAppearance(wallpaper: wallpaper, bubble: bubble);
  }
}

/// Paints [wallpaper] behind the messages.
///
/// Deterministic from [seed] — the conversation's JID — so the pattern does not
/// change between rebuilds.
class WallpaperPainter extends CustomPainter {
  const WallpaperPainter({
    required this.wallpaper,
    required this.base,
    required this.accent,
    required this.seed,
  });

  final Wallpaper wallpaper;
  final Color base;

  /// Theme accent used to tint the pattern.
  final Color accent;
  final String seed;

  @override
  void paint(Canvas canvas, Size size) {
    if (wallpaper == Wallpaper.none) {
      canvas.drawRect(Offset.zero & size, Paint()..color = base);
      return;
    }
    canvas.drawRect(Offset.zero & size, Paint()..color = base);

    final rng = math.Random(seed.hashCode);
    final ox = rng.nextDouble() * 40;
    final oy = rng.nextDouble() * 40;

    final paint = Paint()
      ..color = accent.withValues(alpha: 0.06)
      ..style = PaintingStyle.fill
      ..strokeWidth = 1.2;

    switch (wallpaper) {
      case Wallpaper.none:
        break;

      case Wallpaper.dots:
        const step = 28.0;
        paint.style = PaintingStyle.fill;
        for (var y = oy % step; y < size.height; y += step) {
          for (var x = ox % step; x < size.width; x += step) {
            canvas.drawCircle(Offset(x, y), 1.6, paint);
          }
        }

      case Wallpaper.diagonal:
        paint.style = PaintingStyle.stroke;
        for (var x = -size.height + ox; x < size.width; x += 18) {
          canvas.drawLine(
            Offset(x, size.height),
            Offset(x + size.height, 0),
            paint,
          );
        }

      case Wallpaper.rings:
        paint.style = PaintingStyle.stroke;
        final centre = Offset(ox, oy);
        for (var r = 60.0; r < size.longestSide * 1.4; r += 46) {
          canvas.drawCircle(centre, r, paint);
        }

      case Wallpaper.stripes:
        paint.style = PaintingStyle.fill;
        const step = 44.0;
        for (var x = ox % step; x < size.width; x += step * 2) {
          canvas.drawRect(Rect.fromLTWH(x, 0, step, size.height), paint);
        }

      case Wallpaper.gradient:
        canvas.drawRect(
          Offset.zero & size,
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [accent.withValues(alpha: 0.10), base],
            ).createShader(Offset.zero & size),
        );
    }
  }

  @override
  bool shouldRepaint(WallpaperPainter old) =>
      old.wallpaper != wallpaper ||
      old.base != base ||
      old.accent != accent ||
      old.seed != seed;
}

/// The corner radii for a bubble in [style], for a bubble on [side].
BorderRadius bubbleRadii(BubbleStyle style, bool mine) {
  const r = 14.0;
  const small = 4.0;
  return switch (style) {
    BubbleStyle.rounded => BorderRadius.circular(r),
    BubbleStyle.square => BorderRadius.circular(small),
    BubbleStyle.asymmetric =>
      mine
          ? const BorderRadius.only(
              topLeft: Radius.circular(small),
              topRight: Radius.circular(r),
              bottomRight: Radius.circular(r),
              bottomLeft: Radius.circular(small),
            )
          : const BorderRadius.only(
              topLeft: Radius.circular(r),
              topRight: Radius.circular(small),
              bottomRight: Radius.circular(small),
              bottomLeft: Radius.circular(r),
            ),
  };
}

/// Picks the wallpaper and bubble shape for one conversation.
class AppearancePicker extends StatefulWidget {
  const AppearancePicker({
    super.key,
    required this.initial,
    required this.onChanged,
  });

  final ChatAppearance initial;

  /// Called on every change, including the choice to go back to the default.
  final ValueChanged<ChatAppearance?> onChanged;

  @override
  State<AppearancePicker> createState() => _AppearancePickerState();
}

class _AppearancePickerState extends State<AppearancePicker> {
  late ChatAppearance _current = widget.initial;

  void _update(ChatAppearance next) {
    setState(() => _current = next);
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.appearanceBackground, style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          SizedBox(
            height: 64,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: Wallpaper.values.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, i) {
                final w = Wallpaper.values[i];
                final selected = w == _current.wallpaper;
                return _Swatch(
                  selected: selected,
                  child: InkWell(
                    onTap: () => _update(
                      ChatAppearance(wallpaper: w, bubble: _current.bubble),
                    ),
                    child: CustomPaint(
                      painter: WallpaperPainter(
                        wallpaper: w,
                        base: theme.colorScheme.surface,
                        accent: theme.colorScheme.primary,
                        seed: 'preview',
                      ),
                      child: const SizedBox.expand(),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 16),
          Text(l10n.appearanceBubbleShape, style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          SegmentedButton<BubbleStyle>(
            segments: [
              ButtonSegment(
                value: BubbleStyle.rounded,
                label: Text(l10n.appearanceBubbleRound),
              ),
              ButtonSegment(
                value: BubbleStyle.square,
                label: Text(l10n.appearanceBubbleSquare),
              ),
              ButtonSegment(
                value: BubbleStyle.asymmetric,
                label: Text(l10n.appearanceBubbleTailed),
              ),
            ],
            selected: {_current.bubble},
            onSelectionChanged: (s) => _update(
              ChatAppearance(wallpaper: _current.wallpaper, bubble: s.first),
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => widget.onChanged(null),
              child: Text(l10n.reset),
            ),
          ),
        ],
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.selected, required this.child});

  final bool selected;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 52,
      height: 52,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: selected
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.outlineVariant,
          width: selected ? 3 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}
