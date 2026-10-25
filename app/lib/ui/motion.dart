// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Shared motion vocabulary.
//
// One set of durations and curves keeps every surface moving at the same
// tempo. Without it, one panel slides for 280ms with easeOutCubic, another
// pops in instantly, and the app reads as a collection of unrelated screens.
//
// The durations are deliberately short. These are interface transitions, not
// entertainment: anything above ~350ms starts to feel like waiting for the
// app rather than moving with it.

import 'package:flutter/material.dart';

/// A state change that must feel immediate: hover, press, small fades.
const Duration kMotionFast = Duration(milliseconds: 140);

/// The default for panels, bubbles, and content swaps.
const Duration kMotionBase = Duration(milliseconds: 220);

/// A route or a large panel that travels a meaningful distance.
const Duration kMotionSlow = Duration(milliseconds: 320);

/// Material's emphasised deceleration: fast out of the gate, soft landing.
const Curve kMotionStandard = Cubic(0.2, 0.0, 0.0, 1.0);

/// Entering content. Slightly more front-loaded than [kMotionStandard].
const Curve kMotionEnter = Cubic(0.05, 0.7, 0.1, 1.0);

/// Leaving content. Stays visible briefly, then gets out of the way.
const Curve kMotionExit = Cubic(0.3, 0.0, 0.8, 0.15);

/// Text/content replacement. The old child is gone before the new one starts
/// fading in, so two different strings never paint on top of each other.
const Curve kMotionSwapOut = Interval(0.0, 0.38, curve: kMotionExit);
const Curve kMotionSwapIn = Interval(0.38, 1.0, curve: kMotionEnter);

/// [duration], or zero when the platform asks for reduced motion.
Duration motionDuration(BuildContext context, Duration duration) =>
    (MediaQuery.maybeDisableAnimationsOf(context) ?? false)
    ? Duration.zero
    : duration;

/// An inline surface that grows, shrinks, and fades as [visible] changes.
///
/// Built for Column children such as the reply strip, notices, and the sticker
/// panel: their height is content-driven, and adding them in one frame makes
/// the composer jump. [SizeTransition] drives the surrounding layout while the
/// fade hides the first/last frame of the clipped content.
class MotionCollapse extends StatelessWidget {
  const MotionCollapse({
    super.key,
    required this.visible,
    required this.child,
    this.axis = Axis.vertical,
    this.duration = kMotionBase,
  });

  final bool visible;
  final Widget child;
  final Axis axis;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final effective = reduceMotion ? Duration.zero : duration;
    return AnimatedSwitcher(
      duration: effective,
      switchInCurve: kMotionEnter,
      switchOutCurve: kMotionExit,
      transitionBuilder: (child, animation) {
        return FadeTransition(
          opacity: animation,
          child: SizeTransition(
            sizeFactor: animation,
            axis: axis,
            // Keep the child at its natural cross-axis width. Without this,
            // SizeTransition gives a vertical child the full available width
            // and centres it, which visibly detaches a translation or a short
            // reaction run from the bubble edge it belongs to.
            fixedCrossAxisSizeFactor: 1.0,
            alignment: axis == Axis.vertical
                ? Alignment.topCenter
                : Alignment.centerLeft,
            child: child,
          ),
        );
      },
      child: visible
          ? KeyedSubtree(key: const ValueKey('visible'), child: child)
          : const SizedBox.shrink(key: ValueKey('hidden')),
    );
  }
}
