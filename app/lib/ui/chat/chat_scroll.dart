// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Transcript scrolling for a reverse ListView.builder (newest at min extent).
//
// Off-screen children have no RenderObject, so a [GlobalKey] alone cannot jump
// to a reply or unread divider. Approximate by ascending row index, then
// [bringKeyedIntoView] once the key mounts. Never force a center alignment:
// a message already at the bottom must stay at the bottom.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Scrolls the least amount so [key] is fully visible.
///
/// Uses leading/trailing [RenderAbstractViewport.getOffsetToReveal] rather
/// than a fixed mid-viewport alignment (which pulled bottom rows into the
/// center). Returns false when [key] has no layout yet.
bool bringKeyedIntoView(
  ScrollController controller,
  GlobalKey key, {
  bool animate = true,
  Duration duration = const Duration(milliseconds: 220),
}) {
  final target = key.currentContext;
  if (target == null || !controller.hasClients) return false;
  final renderObject = target.findRenderObject();
  if (renderObject == null || !renderObject.attached) return false;
  final viewport = RenderAbstractViewport.maybeOf(renderObject);
  if (viewport == null) return false;

  final leading = viewport.getOffsetToReveal(renderObject, 0.0).offset;
  final trailing = viewport.getOffsetToReveal(renderObject, 1.0).offset;
  final minEdge = math.min(leading, trailing);
  final maxEdge = math.max(leading, trailing);
  final position = controller.position;
  final current = position.pixels;

  // Already fully visible in the scroll range that keeps the child on screen.
  if (current >= minEdge - 0.5 && current <= maxEdge + 0.5) {
    return true;
  }

  // Pick the nearest edge so we never drag a bottom row up into the center.
  final targetOffset = (current - minEdge).abs() <= (current - maxEdge).abs()
      ? minEdge
      : maxEdge;
  final offset = targetOffset.clamp(
    position.minScrollExtent,
    position.maxScrollExtent,
  );
  if ((offset - current).abs() <= 0.5) return true;

  if (animate && (offset - current).abs() < _shortAnimatePx(position)) {
    unawaited(
      controller.animateTo(offset, duration: duration, curve: Curves.easeOut),
    );
  } else {
    controller.jumpTo(offset);
  }
  return true;
}

double _shortAnimatePx(ScrollPosition position) {
  final viewport = position.viewportDimension;
  if (viewport <= 0) return 600;
  return viewport * 1.5;
}

/// Ascending row 0 (oldest) → near max; last row (newest) → near min.
double _estimatedRowOffset({
  required ScrollController controller,
  required int rowIndex,
  required int rowCount,
}) {
  if (!controller.hasClients) return 0;
  final position = controller.position;
  final min = position.minScrollExtent;
  final max = position.maxScrollExtent;
  if (rowCount <= 1) return min;
  final fraction = (rowIndex / (rowCount - 1)).clamp(0.0, 1.0);
  return (max - (max - min) * fraction).clamp(min, max);
}

/// Jumps toward [rowIndex], then brings [key] into view once it mounts.
///
/// [rowIndex] / [rowCount] are in ascending transcript space (same as
/// [buildTranscriptRows]). Re-estimates each frame while the key is missing.
void scrollToRow({
  required ScrollController controller,
  required GlobalKey key,
  required int rowIndex,
  required int rowCount,
  required bool Function() isMounted,
  bool animate = true,
  int maxAttempts = 32,
  VoidCallback? onDone,
}) {
  void done() {
    onDone?.call();
  }

  void refine({required int attempt, required bool allowAnimate}) {
    if (!isMounted()) return;
    if (bringKeyedIntoView(controller, key, animate: allowAnimate && animate)) {
      done();
      return;
    }
    if (attempt >= maxAttempts) {
      done();
      return;
    }
    if (controller.hasClients && rowCount > 0) {
      final next = _estimatedRowOffset(
        controller: controller,
        rowIndex: rowIndex,
        rowCount: rowCount,
      );
      if ((controller.position.pixels - next).abs() > 0.5) {
        controller.jumpTo(next);
      }
    }
    SchedulerBinding.instance.addPostFrameCallback(
      (_) => refine(attempt: attempt + 1, allowAnimate: false),
    );
  }

  void start({required int wait}) {
    if (!isMounted()) return;
    if (!controller.hasClients) {
      if (wait >= maxAttempts) {
        done();
        return;
      }
      SchedulerBinding.instance.addPostFrameCallback(
        (_) => start(wait: wait + 1),
      );
      return;
    }
    if (bringKeyedIntoView(controller, key, animate: animate)) {
      done();
      return;
    }
    controller.jumpTo(
      _estimatedRowOffset(
        controller: controller,
        rowIndex: rowIndex,
        rowCount: rowCount,
      ),
    );
    SchedulerBinding.instance.addPostFrameCallback(
      (_) => refine(attempt: 0, allowAnimate: animate),
    );
  }

  SchedulerBinding.instance.addPostFrameCallback((_) => start(wait: 0));
}

/// Scrolls to the newest end ([ScrollPosition.minScrollExtent] for reverse).
///
/// Long distances snap; a short glide only when already near the latest end
/// (send / FAB). A couple of settle frames cover a just-inserted bubble.
void scrollToLatest({
  required ScrollController controller,
  required bool Function() isMounted,
  bool animate = true,
  int maxPasses = 8,
  VoidCallback? onDone,
}) {
  var animated = false;

  void settle(int pass) {
    if (!isMounted() || !controller.hasClients) {
      if (isMounted() && pass < maxPasses) {
        SchedulerBinding.instance.addPostFrameCallback((_) => settle(pass + 1));
      } else {
        onDone?.call();
      }
      return;
    }
    final position = controller.position;
    final target = position.minScrollExtent;
    final remaining = position.pixels - target;

    if (remaining <= 0.5 || pass >= maxPasses) {
      if (remaining > 0.5) position.jumpTo(target);
      onDone?.call();
      return;
    }

    final canAnimate =
        animate && !animated && remaining <= _shortAnimatePx(position);
    if (canAnimate) {
      animated = true;
      final duration = Duration(
        milliseconds: (160 + remaining * 0.2).clamp(160, 280).round(),
      );
      controller
          .animateTo(target, duration: duration, curve: Curves.easeOutCubic)
          .then((_) {
            if (!isMounted() || !controller.hasClients) return;
            SchedulerBinding.instance.addPostFrameCallback(
              (_) => settle(pass + 1),
            );
          });
      return;
    }

    position.jumpTo(target);
    SchedulerBinding.instance.addPostFrameCallback((_) => settle(pass + 1));
  }

  SchedulerBinding.instance.addPostFrameCallback((_) => settle(0));
}
