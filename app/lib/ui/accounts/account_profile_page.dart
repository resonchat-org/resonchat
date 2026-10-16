// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Edit own nickname (XEP-0172) and avatar (XEP-0084), Conversations
// EditAccountActivity + PublishProfilePictureActivity.
// OMEMO fingerprint / regenerate / clear-other-devices match EditAccountActivity.

import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:moxxmpp/moxxmpp.dart' show PresenceShow;

import '../../account/account_hub.dart';
import '../../crypto/omemo/fingerprint_trust.dart';
import '../../crypto/own_fingerprints.dart';
import '../../l10n/l10n.dart';
import '../../state/providers.dart';
import '../../store/account_store.dart';
import '../../xmpp/avatar.dart';
import '../../xmpp/connection.dart';
import '../contact_avatar.dart';
import '../fingerprint_box.dart';
import '../theme.dart';

class AccountProfilePage extends ConsumerStatefulWidget {
  const AccountProfilePage({super.key, required this.accountId});

  final String accountId;

  @override
  ConsumerState<AccountProfilePage> createState() => _AccountProfilePageState();
}

class _AccountProfilePageState extends ConsumerState<AccountProfilePage> {
  late final TextEditingController _nick;
  bool _busy = false;
  Uint8List? _preview;
  String? _hybridFingerprint;
  String? _legacyFingerprint;
  int? _deviceId;
  List<PeerFingerprintRow> _otherDevices = const [];

  StoredAccount? get _account {
    for (final a in accountHub.accounts) {
      if (a.id == widget.accountId) return a;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _nick = TextEditingController(text: _account?.displayName ?? '');
    unawaited(_loadOmemo());
  }

  @override
  void dispose() {
    _nick.dispose();
    super.dispose();
  }

  Future<void> _loadOmemo() async {
    final session = accountHub.session(widget.accountId);
    if (session == null) return;
    final store = session.xmpp.deviceStore;
    if (store == null) return;
    try {
      final om = session.xmpp.omemo;
      final device = om != null ? await om.getDevice() : await store.load();
      if (device == null) return;
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
      List<PeerFingerprintRow> others = const [];
      try {
        others = await session.xmpp.ownOtherDeviceFingerprintRows();
      } catch (_) {
        // Device list / bundles may be unavailable offline.
      }
      if (!mounted) return;
      setState(() {
        _deviceId = id;
        _hybridFingerprint = (hybridFromTrack?.isNotEmpty ?? false)
            ? hybridFromTrack
            : (fps.hybrid.isEmpty ? null : fps.hybrid);
        _legacyFingerprint = fps.legacy;
        _otherDevices = others;
      });
    } catch (_) {
      // No device yet.
    }
  }

  bool get _omemoConnected {
    final session = accountHub.session(widget.accountId);
    return session != null &&
        session.xmpp.state == XmppConnectionState.connected;
  }

  Future<void> _copyFingerprint(String? fp) async {
    if (fp == null || fp.isEmpty) return;
    // monocles copies the raw hex (no spaces); peers often paste that.
    await Clipboard.setData(
      ClipboardData(text: fp.replaceAll(RegExp(r'\s+'), '').toLowerCase()),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(context.l10n.fingerprintCopied)));
  }

  Future<void> _confirmRegenerate({required bool pq}) async {
    final l10n = context.l10n;
    if (!_omemoConnected) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.omemoConnectRequired)));
      return;
    }
    final title = pq ? l10n.regenerateOmemo2Key : l10n.regenerateOmemoKey;
    final desc = pq
        ? l10n.regenerateOmemo2KeyDesc
        : l10n.regenerateOmemoKeyDesc;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(desc),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(title),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _runOmemoAction(
      action: (xmpp) =>
          pq ? xmpp.regenerateOmemo2Keys() : xmpp.regenerateOmemoKeys(),
      okMessage: pq ? l10n.omemo2KeyRegenerated : l10n.omemoKeyRegenerated,
      failMessage: pq
          ? l10n.omemo2KeyRegenerateFailed
          : l10n.omemoKeyRegenerateFailed,
      successWhen: pq ? (r) => r == true : null,
    );
  }

  Future<void> _confirmClearDevices({required bool pq}) async {
    final l10n = context.l10n;
    if (!_omemoConnected) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.omemoConnectRequired)));
      return;
    }
    final title = pq
        ? l10n.clearOtherOmemo2Devices
        : l10n.clearOtherOmemoDevices;
    final desc = pq
        ? l10n.clearOtherOmemo2DevicesDesc
        : l10n.clearOtherOmemoDevicesDesc;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(desc),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.accept),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _runOmemoAction(
      action: (xmpp) =>
          pq ? xmpp.wipeOtherOmemo2Devices() : xmpp.wipeOtherOmemoDevices(),
      okMessage: pq ? l10n.omemo2DevicesCleared : l10n.omemoDevicesCleared,
      failMessage: pq
          ? l10n.omemo2DevicesClearFailed
          : l10n.omemoDevicesClearFailed,
      successWhen: (r) => r == true,
    );
  }

  Future<void> _runOmemoAction({
    required Future<Object?> Function(XmppService xmpp) action,
    required String okMessage,
    required String failMessage,
    bool Function(Object? result)? successWhen,
  }) async {
    final session = accountHub.session(widget.accountId);
    if (session == null) return;
    setState(() => _busy = true);
    try {
      final result = await action(session.xmpp);
      final ok = successWhen?.call(result) ?? true;
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(ok ? okMessage : failMessage)));
      if (ok) await _loadOmemo();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(failMessage)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickAvatar() async {
    final l10n = context.l10n;
    final picked = await FilePicker.pickFile(type: FileType.image);
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    if (bytes.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.couldNotOpenFile)));
      return;
    }
    setState(() {
      _busy = true;
      _preview = bytes;
    });
    final session = accountHub.session(widget.accountId);
    final ok = session == null
        ? false
        : await session.xmpp.publishOwnAvatarBytes(bytes);
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      final prepared = await prepareAvatarImage(bytes);
      if (!mounted) return;
      final jid = _account?.bareJid;
      if (prepared != null && jid != null) {
        seedAvatarCache(jid, prepared.bytes);
        final hash = await prepared.hash;
        if (!mounted) return;
        final db = accountHub.session(widget.accountId)?.db;
        if (db != null) await noteAvatarChanged(db, jid, hash);
        if (!mounted) return;
      }
      ref.read(avatarRevisionProvider.notifier).state++;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.avatarPublished)));
    } else {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.avatarPublishFailed)));
    }
  }

  Future<void> _saveNick() async {
    final l10n = context.l10n;
    setState(() => _busy = true);
    final ok = await accountHub.setDisplayName(widget.accountId, _nick.text);
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? l10n.displayNameSaved : l10n.displayNameSaveFailed),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tg = context.tg;
    return ListenableBuilder(
      listenable: accountHub,
      builder: (context, _) {
        final account = _account;
        if (account == null) {
          return Scaffold(
            appBar: AppBar(title: Text(l10n.editProfile)),
            body: Center(child: Text(l10n.noAccountsYet)),
          );
        }
        return Scaffold(
          appBar: AppBar(title: Text(l10n.editProfile)),
          body: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Center(
                child: Padding(
                  padding: avatarCameraBadgePadding(48),
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      if (_preview != null)
                        ClipOval(
                          child: Image.memory(
                            _preview!,
                            width: 96,
                            height: 96,
                            fit: BoxFit.cover,
                          ),
                        )
                      else
                        ContactAvatar(
                          jid: account.bareJid,
                          title: account.label,
                          radius: 48,
                        ),
                      AvatarCameraBadge(
                        avatarRadius: 48,
                        tooltip: l10n.changeAvatar,
                        onPressed: _busy
                            ? null
                            : () => unawaited(_pickAvatar()),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Center(
                child: Text(
                  account.bareJid,
                  style: TextStyle(color: tg.textSecondary),
                ),
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _nick,
                enabled: !_busy,
                decoration: InputDecoration(labelText: l10n.displayName),
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => unawaited(_saveNick()),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _busy ? null : () => unawaited(_saveNick()),
                child: _busy
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(l10n.save),
              ),
              const SizedBox(height: 28),
              Text(
                l10n.presenceStatus,
                style: TextStyle(
                  color: tg.textSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              _PresencePicker(accountId: widget.accountId, enabled: !_busy),
              const SizedBox(height: 28),
              Text(
                l10n.omemoEncryption,
                style: TextStyle(
                  color: tg.textSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.smartphone),
                title: Text(l10n.thisDeviceId('${_deviceId ?? '—'}')),
              ),
              // monocles EditAccount: both stacks shown side-by-side, never merged.
              if (_hybridFingerprint != null) ...[
                Text(
                  l10n.omemo2Fingerprint,
                  style: TextStyle(fontSize: 12, color: tg.textSecondary),
                ),
                const SizedBox(height: 6),
                FingerprintBox(
                  fingerprint: _hybridFingerprint!,
                  margin: EdgeInsets.zero,
                  enabled: !_busy,
                  onCopy: () => unawaited(_copyFingerprint(_hybridFingerprint)),
                ),
              ],
              if (_legacyFingerprint != null) ...[
                const SizedBox(height: 12),
                Text(
                  l10n.omemoLegacyFingerprint,
                  style: TextStyle(fontSize: 12, color: tg.textSecondary),
                ),
                const SizedBox(height: 6),
                FingerprintBox(
                  fingerprint: _legacyFingerprint!,
                  margin: EdgeInsets.zero,
                  enabled: !_busy,
                  onCopy: () => unawaited(_copyFingerprint(_legacyFingerprint)),
                ),
              ],
              const SizedBox(height: 20),
              Text(
                l10n.otherOwnDevices,
                style: TextStyle(
                  color: tg.textSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                l10n.otherOwnDevicesIntro,
                style: TextStyle(fontSize: 12, color: tg.textSecondary),
              ),
              const SizedBox(height: 8),
              if (_otherDevices.isEmpty)
                Text(
                  l10n.noOtherOwnDevices,
                  style: TextStyle(fontSize: 13, color: tg.textSecondary),
                )
              else
                ..._otherDevices.expand((row) {
                  final label = l10n.ownOtherDeviceLabel(
                    row.deviceId,
                    row.omemo2
                        ? l10n.omemo2FingerprintShort
                        : l10n.omemoLegacyFingerprintShort,
                  );
                  return [
                    Text(
                      row.active ? label : l10n.omemoFingerprintInactive(label),
                      style: TextStyle(fontSize: 12, color: tg.textSecondary),
                    ),
                    const SizedBox(height: 6),
                    FingerprintBox(
                      fingerprint: row.fingerprint,
                      margin: EdgeInsets.zero,
                      enabled: !_busy,
                      onCopy: () =>
                          unawaited(_copyFingerprint(row.fingerprint)),
                    ),
                    const SizedBox(height: 12),
                  ];
                }),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.refresh, color: tg.accent),
                title: Text(l10n.regenerateOmemoKey),
                enabled: !_busy,
                onTap: () => unawaited(_confirmRegenerate(pq: false)),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.refresh, color: tg.accent),
                title: Text(l10n.regenerateOmemo2Key),
                enabled: !_busy,
                onTap: () => unawaited(_confirmRegenerate(pq: true)),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.devices_other, color: tg.accent),
                title: Text(l10n.clearOtherOmemoDevices),
                enabled: !_busy,
                onTap: () => unawaited(_confirmClearDevices(pq: false)),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.devices_other, color: tg.accent),
                title: Text(l10n.clearOtherOmemo2Devices),
                enabled: !_busy,
                onTap: () => unawaited(_confirmClearDevices(pq: true)),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// RFC 6121 `<show/>` picker — broadcasts via [XmppService.setOwnPresence].
class _PresencePicker extends StatefulWidget {
  const _PresencePicker({required this.accountId, required this.enabled});

  final String accountId;
  final bool enabled;

  @override
  State<_PresencePicker> createState() => _PresencePickerState();
}

class _PresencePickerState extends State<_PresencePicker> {
  static const _options = <PresenceShow>[
    PresenceShow.online,
    PresenceShow.chat,
    PresenceShow.away,
    PresenceShow.xa,
    PresenceShow.dnd,
  ];

  late PresenceShow _current;

  @override
  void initState() {
    super.initState();
    _current =
        accountHub.session(widget.accountId)?.xmpp.ownShow ?? PresenceShow.chat;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final session = accountHub.session(widget.accountId);

    String label(PresenceShow show) => switch (show) {
      PresenceShow.online => l10n.presenceOnline,
      PresenceShow.chat => l10n.presenceChat,
      PresenceShow.away => l10n.presenceAway,
      PresenceShow.xa => l10n.presenceXa,
      PresenceShow.dnd => l10n.presenceDnd,
    };

    return Column(
      children: [
        for (final show in _options)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: PresenceStatusDot.colorFor(show),
              ),
            ),
            title: Text(label(show)),
            trailing: _current == show
                ? Icon(Icons.check, color: context.tg.accent)
                : null,
            onTap: !widget.enabled || session == null
                ? null
                : () => unawaited(_set(session, show)),
          ),
      ],
    );
  }

  Future<void> _set(AccountSession session, PresenceShow show) async {
    await session.xmpp.setOwnPresence(show);
    await session.db.setOwnPresenceShowWire(show.wire ?? 'online');
    if (mounted) setState(() => _current = show);
  }
}
