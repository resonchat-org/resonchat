// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// ResonChat brand mark, drawn without extra dependencies.
//
// Colour: the theme accent (Material You / system accent when available,
// otherwise the fixed blue accent), with brand blue as the last fallback.
// The mark itself is a speech bubble plus one sine period — see
// docs/13-branding.md.

import 'package:flutter/material.dart';

import 'package:resonchat/ui/theme.dart';

/// Brand fallback used when no theme accent is available.
const Color kResonChatBrandBlue = Color(0xFF3D9BD4);

/// Square ResonChat brand mark.
///
/// [color] overrides the theme accent; when omitted, the ambient
/// [AppColors.accent] is used so the mark follows Material You on Android
/// and the platform accent on desktop.
class ResonChatLogo extends StatelessWidget {
  const ResonChatLogo({super.key, this.size = 48, this.color});

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final resolved = color ?? context.appColors.accent;
    return Semantics(
      label: 'ResonChat',
      image: true,
      child: SizedBox.square(
        dimension: size,
        child: CustomPaint(painter: _ResonChatLogoPainter(resolved)),
      ),
    );
  }
}

class _ResonChatLogoPainter extends CustomPainter {
  const _ResonChatLogoPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.shortestSide / 192.0;
    canvas.save();
    canvas.scale(scale, scale);

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 12
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final bubble = Path()
      ..moveTo(50, 32)
      ..lineTo(142, 32)
      ..arcToPoint(const Offset(170, 60), radius: const Radius.circular(28))
      ..lineTo(170, 100)
      ..arcToPoint(const Offset(142, 128), radius: const Radius.circular(28))
      ..lineTo(96, 128)
      ..lineTo(56, 162)
      ..lineTo(68, 128)
      ..lineTo(50, 128)
      ..arcToPoint(const Offset(22, 100), radius: const Radius.circular(28))
      ..lineTo(22, 60)
      ..arcToPoint(const Offset(50, 32), radius: const Radius.circular(28))
      ..close();

    final wave = Path()
      ..moveTo(64, 80)
      ..cubicTo(72, 56, 88, 56, 96, 80)
      ..cubicTo(104, 104, 120, 104, 128, 80);

    canvas.drawPath(bubble, paint);
    canvas.drawPath(wave, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ResonChatLogoPainter oldDelegate) =>
      oldDelegate.color != color;
}
