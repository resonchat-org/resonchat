// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Encryption info page: fingerprints users compare in person, and per-device
// trust (Gajim CryptoTrustManager). Four stored levels exist; the set-trust
// menu offers only Verified / Blind / Untrusted — Undecided is automatic
// (new device when blind-trust is off), never a menu choice.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:resonchat/l10n/l10n.dart';
import 'package:resonchat/ui/fingerprint_box.dart';
import 'package:resonchat/ui/security/fingerprint_trust_tile.dart';
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
    final tg = context.appColors;
    final l10n = context.l10n;
    final ui = ref.watch(securityViewModelProvider(widget.chatJid));

    return Scaffold(
      appBar: AppBar(title: Text(l10n.encryption)),
      body: ListView(
        children: [
          _section(context, tg, l10n.devices),
          ListTile(
            leading: const Icon(Icons.smartphone),
            title: Text(l10n.thisDeviceId('${ui.deviceId ?? '—'}')),
            subtitle: Text(l10n.deviceCountedForCarbons),
          ),

          _section(context, tg, l10n.verifyIdentity),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text(
              l10n.verifyIdentityIntro,
              style: context.appText.helper,
            ),
          ),
          if (ui.hybridFingerprint != null) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                l10n.omemo2Fingerprint,
                style: context.appText.caption,
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
                style: context.appText.caption,
              ),
            ),
            const SizedBox(height: 6),
            FingerprintBox(
              fingerprint: ui.legacyFingerprint!,
              onCopy: () => _copyFingerprint(ui.legacyFingerprint),
            ),
          ],

          _section(context, tg, l10n.theirFingerprints),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              l10n.theirFingerprintsIntro,
              style: context.appText.helper,
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
                style: context.appText.helper,
              ),
            )
          else
            for (final row in ui.peerRows!)
              FingerprintTrustTile(
                row: row,
                showPeerJid: ui.isGroup,
                onCopy: () => _copyFingerprint(row.shownFingerprint),
                onTrustChanged: (v) => ref
                    .read(securityViewModelProvider(widget.chatJid).notifier)
                    .setPeerTrust(row, v),
              ),

          const SizedBox(height: 24),
        ],
      ),
    );
  }

  static Widget _section(BuildContext context, AppColors tg, String title) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
        child: Text(
          title,
          style: context.appText.sectionHeader.copyWith(color: tg.accent),
        ),
      );
}
