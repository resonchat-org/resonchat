// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Bordered fingerprint panel with the copy action in the bottom-right
// (security page peer tiles, own fingerprints, Me account profile).

import 'package:flutter/material.dart';

import 'package:resonchat/crypto/fingerprint.dart';
import 'package:resonchat/l10n/l10n.dart';
import 'package:resonchat/ui/theme.dart';

/// Displays a formatted fingerprint with [copyFingerprint] inside the frame.
class FingerprintBox extends StatelessWidget {
  const FingerprintBox({
    super.key,
    required this.fingerprint,
    required this.onCopy,
    this.enabled = true,
    this.margin = const EdgeInsets.symmetric(horizontal: 16),
    this.fontSize = 13,
  });

  final String fingerprint;
  final VoidCallback? onCopy;
  final bool enabled;
  final EdgeInsetsGeometry margin;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final tg = context.tg;
    final l10n = context.l10n;
    return Container(
      width: double.infinity,
      margin: margin,
      padding: const EdgeInsets.fromLTRB(14, 14, 8, 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: tg.separator),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: SelectableText(
              formatFingerprint(fingerprint),
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: fontSize,
                color: tg.textPrimary,
                height: 1.6,
              ),
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: enabled ? onCopy : null,
              icon: const Icon(Icons.copy, size: 16),
              label: Text(l10n.copyFingerprint),
            ),
          ),
        ],
      ),
    );
  }
}
