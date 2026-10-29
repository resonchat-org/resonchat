// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Gajim CryptoTrustManager device row: fingerprint + Verified/Blind/Untrusted
// menu (never Undecided as a choice). Used for peer devices and for other
// devices on our own account (Gajim AccountOmemoTrustGroup).

import 'package:flutter/material.dart';

import 'package:resonchat/crypto/dual/fingerprint_trust.dart';
import 'package:resonchat/crypto/fingerprint.dart';
import 'package:resonchat/l10n/l10n.dart';
import 'package:resonchat/ui/theme.dart';

class FingerprintTrustTile extends StatelessWidget {
  const FingerprintTrustTile({
    super.key,
    required this.row,
    required this.onCopy,
    required this.onTrustChanged,
    this.showPeerJid = false,
    this.enabled = true,
    this.margin = const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
  });

  final PeerFingerprintRow row;
  final VoidCallback onCopy;
  final ValueChanged<FingerprintTrust> onTrustChanged;
  final bool showPeerJid;
  final bool enabled;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    final tg = context.tg;
    final l10n = context.l10n;
    final stackLabel = row.omemo2
        ? l10n.omemo2FingerprintShort
        : l10n.omemoLegacyFingerprintShort;
    final title = row.active
        ? l10n.trustDeviceFingerprint(row.deviceId, stackLabel)
        : l10n.omemoFingerprintInactive(
            l10n.trustDeviceFingerprint(row.deviceId, stackLabel),
          );
    final muted = !row.active;
    final trustChip = Chip(
      label: Text(trustLabel(l10n, row.trust)),
      visualDensity: VisualDensity.compact,
    );
    return Card(
      margin: margin,
      elevation: 0,
      color: tg.pageBackground,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: tg.separator),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                title,
                style: TextStyle(
                  color: muted ? tg.textSecondary : tg.textPrimary,
                ),
              ),
              subtitle: Text(
                [
                  if (showPeerJid) row.peerJid,
                  if (!row.active) l10n.fingerprintInactiveSummary,
                  trustSummary(l10n, row.trust),
                ].join('\n'),
                style: TextStyle(fontSize: 12, color: tg.textSecondary),
              ),
              trailing: enabled
                  ? PopupMenuButton<FingerprintTrust>(
                      tooltip: l10n.setFingerprintTrust,
                      initialValue: row.trust == FingerprintTrust.undecided
                          ? null
                          : row.trust,
                      onSelected: onTrustChanged,
                      itemBuilder: (ctx) => [
                        for (final t in const [
                          FingerprintTrust.verified,
                          FingerprintTrust.blind,
                          FingerprintTrust.untrusted,
                        ])
                          if (t != row.trust)
                            PopupMenuItem(
                              value: t,
                              child: Text(trustLabel(l10n, t)),
                            ),
                      ],
                      child: trustChip,
                    )
                  : trustChip,
            ),
            SelectableText(
              formatFingerprint(row.shownFingerprint),
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                color: muted ? tg.textSecondary : tg.textPrimary,
                height: 1.6,
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: onCopy,
                icon: const Icon(Icons.copy, size: 16),
                label: Text(l10n.copyFingerprint),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String trustLabel(AppLocalizations l10n, FingerprintTrust t) =>
      switch (t) {
        FingerprintTrust.verified => l10n.fingerprintTrustVerified,
        FingerprintTrust.blind => l10n.fingerprintTrustBlind,
        FingerprintTrust.undecided => l10n.fingerprintTrustUndecided,
        FingerprintTrust.untrusted => l10n.fingerprintTrustUntrusted,
      };

  static String trustSummary(AppLocalizations l10n, FingerprintTrust t) =>
      switch (t) {
        FingerprintTrust.verified => l10n.fingerprintTrustVerifiedSummary,
        FingerprintTrust.blind => l10n.fingerprintTrustBlindSummary,
        FingerprintTrust.undecided => l10n.fingerprintTrustUndecidedSummary,
        FingerprintTrust.untrusted => l10n.fingerprintTrustUntrustedSummary,
      };
}
