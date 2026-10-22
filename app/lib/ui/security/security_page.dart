// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Encryption info page: fingerprints users compare in person, and per-device
// trust (Gajim CryptoTrustManager). Four stored levels exist; the set-trust
// menu offers only Verified / Blind / Untrusted — Undecided is automatic
// (new device when blind-trust is off), never a menu choice.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:resonchat/crypto/dual/fingerprint_trust.dart';
import 'package:resonchat/crypto/fingerprint.dart';
import 'package:resonchat/l10n/l10n.dart';
import 'package:resonchat/ui/fingerprint_box.dart';
import 'package:resonchat/ui/security/security_viewmodel.dart';
import 'package:resonchat/ui/theme.dart';

class SecurityPage extends ConsumerStatefulWidget {
  const SecurityPage({super.key, required this.chatJid});

  final String chatJid;

  @override
  ConsumerState<SecurityPage> createState() => _SecurityPageState();
}

class _SecurityPageState extends ConsumerState<SecurityPage> {
  Future<void> _copyFingerprint(String? fp) async {
    if (fp == null || fp.isEmpty) return;
    await Clipboard.setData(
      ClipboardData(text: fp.replaceAll(RegExp(r'\s+'), '').toLowerCase()),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(context.l10n.fingerprintCopied)));
  }

  @override
  Widget build(BuildContext context) {
    final tg = context.tg;
    final l10n = context.l10n;
    final ui = ref.watch(securityViewModelProvider(widget.chatJid));

    return Scaffold(
      appBar: AppBar(title: Text(l10n.encryption)),
      body: ListView(
        children: [
          _section(tg, l10n.devices),
          ListTile(
            leading: const Icon(Icons.smartphone),
            title: Text(l10n.thisDeviceId('${ui.deviceId ?? '—'}')),
            subtitle: Text(l10n.deviceCountedForCarbons),
          ),

          _section(tg, l10n.verifyIdentity),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text(
              l10n.verifyIdentityIntro,
              style: TextStyle(fontSize: 13, color: tg.textSecondary),
            ),
          ),
          if (ui.hybridFingerprint != null) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                l10n.omemo2Fingerprint,
                style: TextStyle(fontSize: 12, color: tg.textSecondary),
              ),
            ),
            const SizedBox(height: 6),
            FingerprintBox(
              fingerprint: ui.hybridFingerprint!,
              onCopy: () => _copyFingerprint(ui.hybridFingerprint),
            ),
            const SizedBox(height: 12),
          ],
          if (ui.legacyFingerprint != null) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                l10n.omemoLegacyFingerprint,
                style: TextStyle(fontSize: 12, color: tg.textSecondary),
              ),
            ),
            const SizedBox(height: 6),
            FingerprintBox(
              fingerprint: ui.legacyFingerprint!,
              onCopy: () => _copyFingerprint(ui.legacyFingerprint),
            ),
          ],

          _section(tg, l10n.theirFingerprints),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              l10n.theirFingerprintsIntro,
              style: TextStyle(fontSize: 13, color: tg.textSecondary),
            ),
          ),
          if (ui.peerLoading)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (ui.peerError != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                l10n.couldNotLoadPeerFingerprints,
                style: TextStyle(color: tg.danger),
              ),
            )
          else if ((ui.peerRows ?? const []).isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                l10n.noPeerFingerprintsYet,
                style: TextStyle(fontSize: 13, color: tg.textSecondary),
              ),
            )
          else
            for (final row in ui.peerRows!)
              _PeerFingerprintTile(
                row: row,
                showPeerJid: ui.isGroup,
                onCopy: () => _copyFingerprint(row.fingerprint),
                onTrustChanged: (v) => ref
                    .read(securityViewModelProvider(widget.chatJid).notifier)
                    .setPeerTrust(row, v),
              ),

          const SizedBox(height: 24),
        ],
      ),
    );
  }

  static Widget _section(TgColors tg, String title) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
    child: Text(
      title,
      style: TextStyle(
        color: tg.accent,
        fontSize: 13,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

class _PeerFingerprintTile extends StatelessWidget {
  const _PeerFingerprintTile({
    required this.row,
    required this.onCopy,
    required this.onTrustChanged,
    this.showPeerJid = false,
  });

  final PeerFingerprintRow row;
  final VoidCallback onCopy;
  final ValueChanged<FingerprintTrust> onTrustChanged;
  final bool showPeerJid;

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
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
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
                  _trustSummary(l10n, row.trust),
                ].join('\n'),
                style: TextStyle(fontSize: 12, color: tg.textSecondary),
              ),
              trailing: PopupMenuButton<FingerprintTrust>(
                tooltip: l10n.setFingerprintTrust,
                initialValue: row.trust == FingerprintTrust.undecided
                    ? null
                    : row.trust,
                onSelected: onTrustChanged,
                // Gajim TrustPopver: Verified / Blind / Untrusted only —
                // never Undecided, and never the level already selected.
                itemBuilder: (ctx) => [
                  for (final t in const [
                    FingerprintTrust.verified,
                    FingerprintTrust.blind,
                    FingerprintTrust.untrusted,
                  ])
                    if (t != row.trust)
                      PopupMenuItem(
                        value: t,
                        child: Text(_trustLabel(l10n, t)),
                      ),
                ],
                child: Chip(
                  label: Text(_trustLabel(l10n, row.trust)),
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ),
            SelectableText(
              formatFingerprint(row.fingerprint),
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: muted ? tg.textSecondary : tg.textPrimary,
                height: 1.5,
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

  static String _trustLabel(AppLocalizations l10n, FingerprintTrust t) =>
      switch (t) {
        FingerprintTrust.verified => l10n.fingerprintTrustVerified,
        FingerprintTrust.blind => l10n.fingerprintTrustBlind,
        FingerprintTrust.undecided => l10n.fingerprintTrustUndecided,
        FingerprintTrust.untrusted => l10n.fingerprintTrustUntrusted,
      };

  static String _trustSummary(AppLocalizations l10n, FingerprintTrust t) =>
      switch (t) {
        FingerprintTrust.verified => l10n.fingerprintTrustVerifiedSummary,
        FingerprintTrust.blind => l10n.fingerprintTrustBlindSummary,
        FingerprintTrust.undecided => l10n.fingerprintTrustUndecidedSummary,
        FingerprintTrust.untrusted => l10n.fingerprintTrustUntrustedSummary,
      };
}
