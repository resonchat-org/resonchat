// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Read ring drawn to the left of an outgoing bubble.
//
// The stroke is always there. The inside is a separate shape: nothing when
// nobody has read, a sector for a partial group, a check when everyone has.
// Tapping is only wired for a private non-anonymous room.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:resonchat/l10n/l10n.dart';
import 'package:resonchat/ui/room/occupant_matrix.dart';
import 'package:resonchat/ui/theme.dart';
import 'package:resonchat/xmpp/muc.dart';

const double _ringSize = 15;
const double _stroke = 1.6;

/// Outer ring plus the inner graphic for [fraction] in `0…1`.
class ReadRing extends StatelessWidget {
  const ReadRing({super.key, required this.fraction, this.onTap});

  final double fraction;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tg = context.tg;
    final clamped = fraction.clamp(0.0, 1.0);
    final done = clamped >= 1;
    final ring = SizedBox(
      width: _ringSize,
      height: _ringSize,
      child: CustomPaint(
        painter: _ReadRingPainter(
          fraction: clamped,
          ringColor: done ? tg.online : tg.textSecondary,
          fillColor: tg.online,
        ),
      ),
    );
    if (onTap == null) return ring;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: ring,
    );
  }
}

void _drawCheck(Canvas canvas, Offset center, double radius, Paint stroke) {
  final path = Path()
    ..moveTo(center.dx - radius * 0.38, center.dy + radius * 0.02)
    ..lineTo(center.dx - radius * 0.08, center.dy + radius * 0.32)
    ..lineTo(center.dx + radius * 0.42, center.dy - radius * 0.28);
  canvas.drawPath(path, stroke);
}

class _ReadRingPainter extends CustomPainter {
  _ReadRingPainter({
    required this.fraction,
    required this.ringColor,
    required this.fillColor,
  });

  final double fraction;
  final Color ringColor;
  final Color fillColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - _stroke / 2;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = ringColor;
    canvas.drawCircle(center, radius, stroke);
    if (fraction >= 1) {
      _drawCheck(canvas, center, radius, stroke);
      return;
    }
    if (fraction <= 0) return;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius - _stroke - 1),
      -math.pi / 2,
      math.pi * 2 * fraction,
      true,
      Paint()..color = fillColor,
    );
  }

  @override
  bool shouldRepaint(_ReadRingPainter old) =>
      old.fraction != fraction ||
      old.ringColor != ringColor ||
      old.fillColor != fillColor;
}

/// Two matrices: who has read this message, and who has not.
Future<void> showGroupReadSheet(
  BuildContext context, {
  required String roomJid,
  required List<Occupant> read,
  required List<Occupant> unread,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) {
      final tg = context.tg;
      final l10n = context.l10n;
      return SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _heading(tg, l10n.messageReaders),
              OccupantMatrix(roomJid: roomJid, occupants: read),
              _heading(tg, l10n.messageUnreaders),
              OccupantMatrix(roomJid: roomJid, occupants: unread),
            ],
          ),
        ),
      );
    },
  );
}

Widget _heading(TgColors tg, String label) {
  return Padding(
    padding: const EdgeInsets.fromLTRB(8, 12, 16, 4),
    child: Text(
      label,
      style: TextStyle(
        color: tg.textSecondary,
        fontSize: 13,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}
