// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Multi-account list chrome (via label / avatar halo) for [DialogCell].

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../account/account_color.dart';
import 'theme.dart';

/// How far the account halo extends past the chat-list avatar.
///
/// The row is [TgDimens.chatsRowHeight] and the avatar is
/// [TgDimens.avatarChats], so this is the slack on each side. The halo
/// fades to nothing at that edge.
const accountHaloBleed = (TgDimens.chatsRowHeight - TgDimens.avatarChats) / 2;

/// Avatar wrapped in an account-colored halo.
///
/// The inside edge is a solid colour. Only the outside fades, and it
/// fades faster than a straight blend so the outer part is faint.
Widget accountAvatarRing({
  required Widget child,
  required Color accent,
  required bool show,
}) {
  if (!show) return child;
  final outer = TgDimens.avatarChats + accountHaloBleed * 2;
  return SizedBox(
    width: outer,
    height: outer,
    child: Stack(
      alignment: Alignment.center,
      children: [
        CustomPaint(
          size: Size.square(outer),
          painter: _AccountHaloPainter(color: accent),
        ),
        child,
      ],
    ),
  );
}

class _AccountHaloPainter extends CustomPainter {
  const _AccountHaloPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final outer = size.shortestSide / 2;
    final innerT = (TgDimens.avatarChats / 2 / outer).clamp(0.0, 1.0);
    // Full colour on the inside of the ring. Alpha is (1-u)^2 across the
    // outer band, so only the outside thins out.
    const steps = 8;
    const hold = 0.2;
    final colors = <Color>[color, color];
    final stops = <double>[0, innerT];
    for (var i = 1; i <= steps; i++) {
      final t = i / steps;
      final u = t <= hold ? 0.0 : (t - hold) / (1 - hold);
      final alpha = math.pow(1 - u, 2).toDouble();
      colors.add(color.withValues(alpha: alpha));
      stops.add(innerT + (1 - innerT) * t);
    }
    final paint = Paint()
      ..shader = RadialGradient(
        colors: colors,
        stops: stops,
      ).createShader(Rect.fromCircle(center: center, radius: outer));
    canvas.drawCircle(center, outer, paint);
  }

  @override
  bool shouldRepaint(covariant _AccountHaloPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// Short “via this account” label under the title.
Widget accountViaText(String accountBareJid, Color accent) {
  return Text(
    accountViaLabel(accountBareJid),
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: TextStyle(
      fontSize: TgDimens.timeFontSize,
      color: accent,
      fontWeight: FontWeight.w600,
    ),
  );
}
