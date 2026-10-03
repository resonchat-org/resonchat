// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Chat appearance: wallpaper, bubble shape, and the colours that follow from
// them.
//
// Telegram's visual identity is largely this, and it is the cheapest part of
// "feels like Telegram" to get right — no permission, no network, no protocol.
//
// Two decisions carry most of the weight:
//
//   * Appearance is **per conversation**, not global. Telegram lets you pick a
//     different colour for one person, and that is the feature people actually
//     use; a single global setting is a settings screen with nothing in it.
//   * A pattern is drawn by Flutter, not loaded from disk. Reading an image file
//     is a permission, and this app asks for none. So the patterns are code:
//     deterministic, no I/O, and they survive a reinstall identically.

import 'dart:math' as math;

import 'package:flutter/material.dart';

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
    this.accent,
  });

  final Wallpaper wallpaper;
  final BubbleStyle bubble;

  /// Overrides the theme accent for this conversation, when set.
  ///
  /// Null means "use the app's accent", which is the default for every
  /// conversation. Storing null rather than the resolved colour is what lets a
  /// later change of theme reach conversations that never overrode it.
  final Color? accent;

  /// Serialised as one character per field, so a row is one short string.
  ///
  /// Wallpaper first, then bubble, then accent as three hex digits of hue —
  /// the stored form is deliberately not a full colour so that a palette
  /// change in a future version can reinterpret it.
  String encode() {
    final hue = accent == null
        ? '---'
        : _hueDigits(accent!);
    return '${wallpaper.index}${bubble.index}$hue';
  }

  /// Reads [encode]d form, falling back to the default for anything
  /// unrecognised.
  ///
  /// Lenient on purpose: a stored value from a future version, or a row written
  /// by a build that had a bug, must not make a conversation unopenable.
  static ChatAppearance decode(String? raw) {
    if (raw == null || raw.length < 2) return const ChatAppearance();
    final wallpaper = Wallpaper.values.asNameMap()[raw[0]] ??
        (int.tryParse(raw[0]) != null &&
                int.tryParse(raw[0])! < Wallpaper.values.length
            ? Wallpaper.values[int.parse(raw[0])]
            : Wallpaper.none);
    final bubble = BubbleStyle.values.asNameMap()[raw[1]] ??
        (int.tryParse(raw[1]) != null &&
                int.tryParse(raw[1])! < BubbleStyle.values.length
            ? BubbleStyle.values[int.parse(raw[1])]
            : BubbleStyle.rounded);
    final hue = raw.length >= 5 ? int.tryParse(raw.substring(2, 5)) : null;
    return ChatAppearance(
      wallpaper: wallpaper,
      bubble: bubble,
      accent: hue == null
          ? null
          : HSLColor.fromAHSL(1, hue.toDouble(), 0.55, 0.5).toColor(),
    );
  }

  static String _hueDigits(Color c) {
    final hue = HSLColor.fromColor(c).hue.round().clamp(0, 359);
    return hue.toString().padLeft(3, '0');
  }
}

/// Paints [wallpaper] behind the messages.
///
/// Deterministic from [seed] — the conversation's JID — so the pattern does not
/// change between rebuilds. A pattern that re-randomised itself on every frame
/// would make the transcript look like it was shimmering.
class WallpaperPainter extends CustomPainter {
  const WallpaperPainter({
    required this.wallpaper,
    required this.base,
    required this.accent,
    required this.seed,
  });

  final Wallpaper wallpaper;
  final Color base;
  final Color accent;
  final String seed;

  @override
  void paint(Canvas canvas, Size size) {
    if (wallpaper == Wallpaper.none) {
      canvas.drawRect(Offset.zero & size, Paint()..color = base);
      return;
    }
    canvas.drawRect(Offset.zero & size, Paint()..color = base);

    // A stable offset per conversation, so two chats do not look identical and
    // one chat does not change between visits.
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
        // Centred off the top-left corner, the way Telegram's radial patterns
        // sit, rather than in the middle of the transcript where they would be
        // hidden behind most of the content.
        final centre = Offset(ox, oy);
        for (var r = 60.0; r < size.longestSide * 1.4; r += 46) {
          canvas.drawCircle(centre, r, paint);
        }

      case Wallpaper.stripes:
        paint.style = PaintingStyle.fill;
        const step = 44.0;
        for (var x = ox % step; x < size.width; x += step * 2) {
          canvas.drawRect(
            Rect.fromLTWH(x, 0, step, size.height),
            paint,
          );
        }

      case Wallpaper.gradient:
        canvas.drawRect(
          Offset.zero & size,
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                accent.withValues(alpha: 0.10),
                base,
              ],
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
///
/// The four corners are named by where they sit relative to the sender, so the
/// asymmetric case is a matter of picking the right pair rather than a stack of
/// conditionals at the call site.
BorderRadius bubbleRadii(BubbleStyle style, bool mine) {
  const r = 14.0;
  const small = 4.0;
  return switch (style) {
    BubbleStyle.rounded => BorderRadius.circular(r),
    BubbleStyle.square => BorderRadius.circular(small),
    BubbleStyle.asymmetric => mine
        // Our own bubble: rounded on the right, square on the left, so the
        // corner nearest the other party is the pointed one.
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

/// Picks the wallpaper, bubble shape and accent for one conversation.
///
/// Every option is previewed with the pattern drawn at the size it will be, not
/// by name: "Dots" and "Stripes" tell the user nothing about what the chat will
/// look like, and the only way to find out is to apply it and look.
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

  /// The accents offered, as hues.
  ///
  /// Spaced rather than random so two of them are never nearly identical, which
  /// is what makes a colour picker feel arbitrary.
  static const _hues = [210, 0, 35, 130, 275, 165];

  void _update(ChatAppearance next) {
    setState(() => _current = next);
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Background', style: theme.textTheme.titleSmall),
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
                  child: CustomPaint(
                    painter: WallpaperPainter(
                      wallpaper: w,
                      base: theme.colorScheme.surface,
                      accent: _current.accent ?? theme.colorScheme.primary,
                      seed: 'preview',
                    ),
                    child: const SizedBox.expand(),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 16),
          Text('Bubble shape', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          SegmentedButton<BubbleStyle>(
            segments: const [
              ButtonSegment(value: BubbleStyle.rounded, label: Text('Round')),
              ButtonSegment(value: BubbleStyle.square, label: Text('Square')),
              ButtonSegment(
                value: BubbleStyle.asymmetric,
                label: Text('Tailed'),
              ),
            ],
            selected: {_current.bubble},
            onSelectionChanged: (s) =>
                _update(ChatAppearance(wallpaper: _current.wallpaper, bubble: s.first, accent: _current.accent)),
          ),
          const SizedBox(height: 16),
          Text('Colour', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          Row(
            children: [
              for (final hue in _hues)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: _Swatch(
                    selected: _current.accent != null &&
                        (HSLColor.fromColor(_current.accent!).hue.round() -
                                    hue)
                                .abs() <
                            4,
                    child: InkWell(
                      onTap: () => _update(
                        ChatAppearance(
                          wallpaper: _current.wallpaper,
                          bubble: _current.bubble,
                          accent: HSLColor.fromAHSL(
                            1,
                            hue.toDouble(),
                            0.55,
                            0.5,
                          ).toColor(),
                        ),
                      ),
                      child: Container(
                        decoration: BoxDecoration(
                          color: HSLColor.fromAHSL(
                            1,
                            hue.toDouble(),
                            0.55,
                            0.5,
                          ).toColor(),
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  ),
                ),
              const Spacer(),
              TextButton(
                onPressed: () => widget.onChanged(null),
                child: const Text('Reset'),
              ),
            ],
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
          // Thicker when selected, so the state does not depend on colour
          // vision alone.
          width: selected ? 3 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}
