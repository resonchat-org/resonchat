// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The blurred card the current Telegram design floats over the transcript:
// the chat header's back/menu blobs, its title pill and the composer island
// are all one of these.
//
// The reference draws them with a `BlurredBackgroundDrawable` built by a
// `BlurredBackgroundDrawableViewFactory` (`ChatActivity.java:4934`, `:4911`),
// against the transcript rendered behind it. Flutter's equivalent is a
// backdrop filter, and the Material one — [BackdropGroup] plus
// [BackdropFilter.grouped] — keeps a single blurred snapshot of the backdrop,
// so several cards cost one blur between them instead of one blur each.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Blur radius of the glass cards.
const double kGlassSigma = 24;

/// A rounded card that blurs the transcript behind it and tints it with [fill].
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.radius,
    required this.fill,
    required this.child,
    this.shadow = true,
  });

  final double radius;
  final Color fill;
  final Widget child;

  /// Whether the card carries its own drop shadow.
  final bool shadow;

  @override
  Widget build(BuildContext context) {
    final corners = BorderRadius.circular(radius);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: corners,
        boxShadow: shadow
            ? [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.14),
                  blurRadius: 10,
                  offset: const Offset(0, 2),
                ),
              ]
            : null,
      ),
      child: ClipRRect(
        borderRadius: corners,
        child: BackdropFilter.grouped(
          filter: ui.ImageFilter.blur(sigmaX: kGlassSigma, sigmaY: kGlassSigma),
          child: ColoredBox(color: fill, child: child),
        ),
      ),
    );
  }
}
