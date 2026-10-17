// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Encryption info page: fingerprints users compare in person, and per-device
// trust toggles (monocles TrustKeysActivity). Distrusted devices are skipped
// on the next encrypt (classic + OMEMO2).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../account/resolve.dart';
import '../../crypto/fingerprint.dart';
import '../../crypto/omemo/fingerprint_trust.dart';
import '../../crypto/own_fingerprints.dart';
import '../../l10n/l10n.dart';
import '../../state/providers.dart';
import '../fingerprint_box.dart';
import '../theme.dart';

class SecurityPage extends ConsumerStatefulWidget {
  const SecurityPage({super.key, required this.chatJid});

  final String chatJid;

  @override
  ConsumerState<SecurityPage> createState() => _SecurityPageState();
}

class _SecurityPageState extends ConsumerState<SecurityPage> {
  String? _hybridFingerprint;
  String? _legacyFingerprint;
  int? _deviceId;
  List<PeerFingerprintRow>? _peerRows;
  bool _peerLoading = true;
  String? _peerError;
  bool _isGroup = false;

  String get _peerBare => resolveChatKey(widget.chatJid).jid;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final session = resolveChatKey(widget.chatJid).session;
    final store = session.xmpp.deviceStore;
    final om = session.xmpp.omemo;
    if (store == null || om == null) {
      if (mounted) setState(() => _peerLoading = false);
      return;
    }
    final device = await om.getDevice();
    final id = await device.deviceId;
    final hybridFromTrack = await session.xmpp.bTrack?.hybridFingerprint();
    List<int>? omemo2Ik;
    final bDev = session.xmpp.bTrack?.device;
    if (bDev != null) {
      omemo2Ik = await bDev.identityPublicSerialized();
    }
    final fps = await loadOwnFingerprints(
      legacyDevice: device,
      pqStore: store.pqIdentity,
      omemo2IkSerialized: omemo2Ik,
    );
    final chat = await session.db.getChat(_peerBare);
    final isGroup = chat?.isGroup ?? false;
    List<PeerFingerprintRow> peers = const [];
    Object? peerErr;
    try {
      if (isGroup) {
        final room = await ref.read(roomStateProvider(widget.chatJid).future);
        final ownBare = session.xmpp.myJid?.toLowerCase();
        final members = <String>{
          for (final o in room?.occupants ?? const [])
            if (o.realJid != null &&
                o.realJid!.isNotEmpty &&
                o.realJid!.toLowerCase() != ownBare)
              o.realJid!,
        };
        peers = await session.xmpp.groupFingerprintRows(members);
      } else {
        peers = await session.xmpp.peerFingerprintRows(_peerBare);
      }
    } catch (e) {
      peerErr = e;
    }
    if (!mounted) return;
    setState(() {
      _deviceId = id;
      _isGroup = isGroup;
      _hybridFingerprint = (hybridFromTrack?.isNotEmpty ?? false)
          ? hybridFromTrack
          : (fps.hybrid.isEmpty ? null : fps.hybrid);
      _legacyFingerprint = fps.legacy;
      _peerRows = peers;
      _peerError = peerErr?.toString();
      _peerLoading = false;
    });
  }

  Future<void> _copyFingerprint(String? fp) async {
    if (fp == null || fp.isEmpty) return;
    await Clipboard.setData(
      ClipboardData(text: fp.replaceAll(RegExp(r'\s+'), '').toLowerCase()),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(context.l10n.fingerprintCopied)));
  }

  Future<void> _setPeerTrust(PeerFingerprintRow row, bool trusted) async {
    final xmpp = resolveChatKey(widget.chatJid).session.xmpp;
    await xmpp.setPeerFingerprintTrust(
      bareJid: row.peerJid,
      fingerprint: row.fingerprint,
      trusted: trusted,
    );
    if (!mounted) return;
    setState(() {
      _peerRows = [
        for (final r in _peerRows ?? const <PeerFingerprintRow>[])
          if (r.fingerprint == row.fingerprint &&
              r.omemo2 == row.omemo2 &&
              r.peerJid == row.peerJid)
            PeerFingerprintRow(
              peerJid: r.peerJid,
              deviceId: r.deviceId,
              fingerprint: r.fingerprint,
              omemo2: r.omemo2,
              trusted: trusted,
              active: r.active,
            )
          else
            r,
      ];
    });
  }

  @override
  Widget build(BuildContext context) {
    final tg = context.tg;
    final l10n = context.l10n;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.encryption)),
      body: ListView(
        children: [
          _section(tg, l10n.devices),
          ListTile(
            leading: const Icon(Icons.smartphone),
            title: Text(l10n.thisDeviceId('${_deviceId ?? '—'}')),
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
          if (_hybridFingerprint != null) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                l10n.omemo2Fingerprint,
                style: TextStyle(fontSize: 12, color: tg.textSecondary),
              ),
            ),
            const SizedBox(height: 6),
            FingerprintBox(
              fingerprint: _hybridFingerprint!,
              onCopy: () => _copyFingerprint(_hybridFingerprint),
            ),
            const SizedBox(height: 12),
          ],
          if (_legacyFingerprint != null) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                l10n.omemoLegacyFingerprint,
                style: TextStyle(fontSize: 12, color: tg.textSecondary),
              ),
            ),
            const SizedBox(height: 6),
            FingerprintBox(
              fingerprint: _legacyFingerprint!,
              onCopy: () => _copyFingerprint(_legacyFingerprint),
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
          if (_peerLoading)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_peerError != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                l10n.couldNotLoadPeerFingerprints,
                style: TextStyle(color: tg.danger),
              ),
            )
          else if ((_peerRows ?? const []).isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                l10n.noPeerFingerprintsYet,
                style: TextStyle(fontSize: 13, color: tg.textSecondary),
              ),
            )
          else
            for (final row in _peerRows!)
              _PeerFingerprintTile(
                row: row,
                showPeerJid: _isGroup,
                onCopy: () => _copyFingerprint(row.fingerprint),
                onTrustChanged: (v) => _setPeerTrust(row, v),
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
  final ValueChanged<bool> onTrustChanged;
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
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: row.trusted,
              onChanged: onTrustChanged,
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
                  row.trusted
                      ? l10n.fingerprintTrustedSummary
                      : l10n.fingerprintDistrustedSummary,
                ].join('\n'),
                style: TextStyle(fontSize: 12, color: tg.textSecondary),
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
}
