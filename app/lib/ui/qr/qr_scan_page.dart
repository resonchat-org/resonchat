// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Conversations `QrCodeScanningActivity` — camera QR → raw payload. The
// caller treats the result like a tapped message link ([activateMessageLink]).
// Desktop (Gajim) has no scanner; only Android / iOS show an entry point.

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';

import 'package:mobile_scanner/mobile_scanner.dart';

import 'package:resonchat/l10n/l10n.dart';
import 'package:resonchat/ui/theme.dart';

/// Camera QR scan is offered on phone/tablet builds only (not desktop/web).
bool get supportsQrScan {
  if (kIsWeb) return false;
  return defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;
}

/// Full-screen scanner. Pops with the first non-empty QR payload, or null.
class QrScanPage extends StatefulWidget {
  const QrScanPage({super.key});

  @override
  State<QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<QrScanPage> {
  late final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.normal,
    formats: const [BarcodeFormat.qrCode],
  );

  var _handled = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    final raw = capture.barcodes
        .map((b) => b.rawValue?.trim() ?? '')
        .firstWhere((s) => s.isNotEmpty, orElse: () => '');
    if (raw.isEmpty) return;
    _handled = true;
    Navigator.of(context).pop(raw);
  }

  void _onDetectError(Object error, StackTrace stackTrace) {
    if (!mounted) return;
    if (error is MobileScannerException &&
        error.errorCode == MobileScannerErrorCode.permissionDenied) {
      setState(() => _error = context.l10n.qrScanCameraDenied);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tg = context.tg;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.scanQrCode)),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: tg.textSecondary),
                ),
              ),
            )
          : MobileScanner(
              controller: _controller,
              onDetect: _onDetect,
              onDetectError: _onDetectError,
            ),
    );
  }
}
