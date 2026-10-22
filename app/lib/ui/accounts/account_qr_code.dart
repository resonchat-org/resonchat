// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Conversations `BarcodeProvider.create2dBarcodeBitmap`: QR, error
// correction L, UTF-8. Quiet zone is ZXing's default margin of 4 modules.
// Modules stay black on white so the code scans in either theme.

import 'package:flutter/material.dart';

import 'package:qr/qr.dart';

import 'package:resonchat/l10n/l10n.dart';

class AccountQrCode extends StatelessWidget {
  const AccountQrCode({super.key, required this.data, this.size = 220});

  final String data;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: context.l10n.accountQrCode,
      child: CustomPaint(size: Size.square(size), painter: _QrPainter(data)),
    );
  }
}

class _QrPainter extends CustomPainter {
  _QrPainter(this.data)
    : image = QrImage(
        QrCode.fromData(data: data, errorCorrectLevel: QrErrorCorrectLevel.L),
      );

  final String data;
  final QrImage image;

  static const _quietZone = 4;

  @override
  void paint(Canvas canvas, Size size) {
    final modules = image.moduleCount + _quietZone * 2;
    final module = size.shortestSide / modules;
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFFFFFFFF),
    );
    final ink = Paint()..color = const Color(0xFF000000);
    for (var y = 0; y < image.moduleCount; y++) {
      for (var x = 0; x < image.moduleCount; x++) {
        if (!image.isDark(y, x)) continue;
        canvas.drawRect(
          Rect.fromLTWH(
            (x + _quietZone) * module,
            (y + _quietZone) * module,
            module,
            module,
          ),
          ink,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _QrPainter oldDelegate) =>
      oldDelegate.data != data;
}
