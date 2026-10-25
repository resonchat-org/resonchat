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

import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
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

/// Page transition shared by every pushed route.
///
/// A small slide plus fade instead of the platform zoom. The distance is short
/// on purpose: a full-width slide is tiring to read on a desktop pane, while
/// no movement at all makes a route change feel like content flickering.
class ResonMotionPageTransitionsBuilder extends PageTransitionsBuilder {
  const ResonMotionPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      return child;
    }
    // Fully settled routes need no wrapper. This also covers the first route
    // at startup, but it is re-evaluated when a push starts, so the page
    // underneath still plays its exit transition instead of being skipped
    // for the lifetime of the route.
    if (animation.value == 1.0 && secondaryAnimation.value == 0.0) {
      return child;
    }

    final enter = CurvedAnimation(
      parent: animation,
      curve: kMotionEnter,
      reverseCurve: kMotionExit,
    );
    // The outgoing page only calms down; it must not appear to move as far as
    // the incoming one or the two layers fight for attention.
    final leave = CurvedAnimation(
      parent: secondaryAnimation,
      curve: kMotionStandard,
      reverseCurve: kMotionStandard,
    );

    return FadeTransition(
      opacity: Tween<double>(begin: 1, end: 0.82).animate(leave),
      child: SlideTransition(
        position: Tween<Offset>(
          begin: Offset.zero,
          end: const Offset(-0.018, 0),
        ).animate(leave),
        child: FadeTransition(
          opacity: enter,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0.035, 0),
              end: Offset.zero,
            ).animate(enter),
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.99, end: 1).animate(enter),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

/// The platform map for [ResonMotionPageTransitionsBuilder].
///
/// The shared slide/fade is used on desktop, where there is no system back
/// gesture. Mobile keeps the platform route transition: replacing it with a
/// plain [PageTransitionsBuilder] removes iOS/macOS edge-swipe-to-pop and
/// Android's predictive-back preview.
const PageTransitionsTheme kMotionPageTransitionsTheme = PageTransitionsTheme(
  builders: <TargetPlatform, PageTransitionsBuilder>{
    TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
    TargetPlatform.fuchsia: ResonMotionPageTransitionsBuilder(),
    TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
    TargetPlatform.linux: ResonMotionPageTransitionsBuilder(),
    TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
    TargetPlatform.windows: ResonMotionPageTransitionsBuilder(),
  },
);

/// Keeps every tab mounted (scroll positions, composers, subscriptions) while
/// cross-fading between them.
///
/// [IndexedStack] preserves state but swaps instantly. Rebuilding only the
/// selected page in an [AnimatedSwitcher] animates nicely but loses that state.
/// This puts all pages in a stack and animates opacity plus a few pixels of
/// horizontal travel; inactive pages ignore pointers and stop their tickers.
class MotionTabStack extends StatelessWidget {
  const MotionTabStack({
    super.key,
    required this.index,
    required this.children,
  });

  final int index;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final duration = reduceMotion ? Duration.zero : kMotionBase;
    return Stack(
      fit: StackFit.expand,
      children: [
        for (var i = 0; i < children.length; i++)
          Positioned.fill(
            child: IgnorePointer(
              ignoring: i != index,
              child: ExcludeSemantics(
                excluding: i != index,
                child: AnimatedOpacity(
                  opacity: i == index ? 1 : 0,
                  duration: duration,
                  curve: kMotionStandard,
                  child: AnimatedSlide(
                    // The old page leaves in the direction of travel, the new
                    // one arrives from the other side. It reads as a stack of
                    // pages rather than a cross-fade of unrelated content.
                    offset: i == index
                        ? Offset.zero
                        : Offset(i < index ? -0.012 : 0.012, 0),
                    duration: duration,
                    curve: kMotionStandard,
                    // The cross-fade itself must keep ticking while the page
                    // is leaving; only the page content stops.
                    child: TickerMode(enabled: i == index, child: children[i]),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

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
