// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Edit own nickname (XEP-0172) and avatar (XEP-0084), Conversations
// EditAccountActivity + PublishProfilePictureActivity.
// OMEMO fingerprint / regenerate / clear-other-devices match EditAccountActivity.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:moxxmpp/moxxmpp.dart' show PresenceShow;

import 'package:resonchat/account/account_hub.dart';
import 'package:resonchat/l10n/l10n.dart';
import 'package:resonchat/persistence/account_store.dart';
import 'package:resonchat/ui/accounts/account_profile_viewmodel.dart';
import 'package:resonchat/ui/accounts/account_qr_code.dart';
import 'package:resonchat/ui/accounts/blocked_contacts_page.dart';
import 'package:resonchat/ui/contact_avatar.dart';
import 'package:resonchat/ui/fingerprint_box.dart';
import 'package:resonchat/ui/security/fingerprint_trust_tile.dart';
import 'package:resonchat/ui/theme.dart';
import 'package:resonchat/xmpp/account_share_uri.dart';
import 'package:resonchat/xmpp/connection.dart';

class AccountProfilePage extends ConsumerStatefulWidget {
  const AccountProfilePage({super.key, required this.accountId});

  final String accountId;

  @override
  ConsumerState<AccountProfilePage> createState() => _AccountProfilePageState();
}

class _AccountProfilePageState extends ConsumerState<AccountProfilePage> {
  late final TextEditingController _nick;

  StoredAccount? get _account {
    for (final a in accountHub.accounts) {
      if (a.id == widget.accountId) return a;
    }
    return null;
  }

  AccountProfileViewModel get _model =>
      ref.read(accountProfileViewModelProvider(widget.accountId).notifier);

  @override
  void initState() {
    super.initState();
    _nick = TextEditingController(text: _account?.displayName ?? '');
  }

  @override
  void dispose() {
    _nick.dispose();
    super.dispose();
  }

  Future<void> _changePassword() async {
    final l10n = context.l10n;
    final account = _account;
    final session = accountHub.session(widget.accountId);
    if (account == null ||
        session == null ||
        session.xmpp.state != XmppConnectionState.connected) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.notConnectedTryAgain)));
      return;
    }
    final submitted = await showDialog<({String current, String next})>(
      context: context,
      builder: (ctx) =>
          _ChangePasswordDialog(currentPassword: account.password),
    );
    if (submitted == null || !mounted) return;
    final ok = await accountHub.changeAccountPassword(
      widget.accountId,
      submitted.next,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? l10n.passwordChanged : l10n.couldNotChangePassword),
      ),
    );
  }

  Future<void> _copyShareUri(String uri) async {
    await Clipboard.setData(ClipboardData(text: uri));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(context.l10n.uriCopied)));
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
    if (!_model.omemoConnected) {
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
    final saved = await _model.regenerateKeys(pq: pq);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          saved
              ? (pq ? l10n.omemo2KeyRegenerated : l10n.omemoKeyRegenerated)
              : (pq
                    ? l10n.omemo2KeyRegenerateFailed
                    : l10n.omemoKeyRegenerateFailed),
        ),
      ),
    );
  }

  Future<void> _confirmClearDevices({required bool pq}) async {
    final l10n = context.l10n;
    if (!_model.omemoConnected) {
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
    final saved = await _model.wipeOtherDevices(pq: pq);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          saved
              ? (pq ? l10n.omemo2DevicesCleared : l10n.omemoDevicesCleared)
              : (pq
                    ? l10n.omemo2DevicesClearFailed
                    : l10n.omemoDevicesClearFailed),
        ),
      ),
    );
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
    final ok = await _model.publishAvatar(bytes);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? l10n.avatarPublished : l10n.avatarPublishFailed),
      ),
    );
  }

  Future<void> _saveNick() async {
    final l10n = context.l10n;
    final ok = await _model.saveDisplayName(_nick.text);
    if (!mounted) return;
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
    final ui = ref.watch(accountProfileViewModelProvider(widget.accountId));
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
        final shareUri = accountShareUri(
          bareJid: account.bareJid,
          deviceId: ui.deviceId,
          legacyFingerprint: ui.legacyFingerprint,
        );
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
                      if (ui.avatarPreview != null)
                        ClipOval(
                          child: Image.memory(
                            ui.avatarPreview!,
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
                        onPressed: ui.busy
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
              const SizedBox(height: 16),
              Center(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AccountQrCode(data: shareUri),
                      IconButton(
                        tooltip: l10n.copyUri,
                        onPressed: () => unawaited(_copyShareUri(shareUri)),
                        icon: const Icon(Icons.copy_outlined),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _nick,
                enabled: !ui.busy,
                decoration: InputDecoration(labelText: l10n.displayName),
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => unawaited(_saveNick()),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: ui.busy ? null : () => unawaited(_saveNick()),
                child: ui.busy
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(l10n.save),
              ),
              const SizedBox(height: 8),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.key),
                title: Text(l10n.changePassword),
                subtitle: Text(l10n.changePasswordSummary),
                enabled: !ui.busy,
                onTap: () => unawaited(_changePassword()),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.block),
                title: Text(l10n.blockedContacts),
                subtitle: Text(l10n.blockedContactsSummary),
                trailing: const Icon(Icons.chevron_right),
                enabled: !ui.busy,
                onTap: () {
                  Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          BlockedContactsPage(accountId: widget.accountId),
                    ),
                  );
                },
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
              _PresencePicker(
                accountId: widget.accountId,
                enabled: !ui.busy,
                onSelected: _model.setPresence,
              ),
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
                title: Text(l10n.thisDeviceId('${ui.deviceId ?? '—'}')),
              ),
              // monocles EditAccount: both stacks shown side-by-side, never merged.
              if (ui.hybridFingerprint != null) ...[
                Text(
                  l10n.omemo2Fingerprint,
                  style: TextStyle(fontSize: 12, color: tg.textSecondary),
                ),
                const SizedBox(height: 6),
                FingerprintBox(
                  fingerprint: ui.hybridFingerprint!,
                  margin: EdgeInsets.zero,
                  enabled: !ui.busy,
                  onCopy: () =>
                      unawaited(_copyFingerprint(ui.hybridFingerprint)),
                ),
              ],
              if (ui.legacyFingerprint != null) ...[
                const SizedBox(height: 12),
                Text(
                  l10n.omemoLegacyFingerprint,
                  style: TextStyle(fontSize: 12, color: tg.textSecondary),
                ),
                const SizedBox(height: 6),
                FingerprintBox(
                  fingerprint: ui.legacyFingerprint!,
                  margin: EdgeInsets.zero,
                  enabled: !ui.busy,
                  onCopy: () =>
                      unawaited(_copyFingerprint(ui.legacyFingerprint)),
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
              if (ui.otherDevices.isEmpty)
                Text(
                  l10n.noOtherOwnDevices,
                  style: TextStyle(fontSize: 13, color: tg.textSecondary),
                )
              else
                for (final row in ui.otherDevices)
                  FingerprintTrustTile(
                    row: row,
                    margin: EdgeInsets.zero,
                    enabled: !ui.busy,
                    onCopy: () => unawaited(_copyFingerprint(row.fingerprint)),
                    onTrustChanged: (v) =>
                        unawaited(_model.setOtherDeviceTrust(row, v)),
                  ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.refresh, color: tg.accent),
                title: Text(l10n.regenerateOmemoKey),
                enabled: !ui.busy,
                onTap: () => unawaited(_confirmRegenerate(pq: false)),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.refresh, color: tg.accent),
                title: Text(l10n.regenerateOmemo2Key),
                enabled: !ui.busy,
                onTap: () => unawaited(_confirmRegenerate(pq: true)),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.devices_other, color: tg.accent),
                title: Text(l10n.clearOtherOmemoDevices),
                enabled: !ui.busy,
                onTap: () => unawaited(_confirmClearDevices(pq: false)),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.devices_other, color: tg.accent),
                title: Text(l10n.clearOtherOmemo2Devices),
                enabled: !ui.busy,
                onTap: () => unawaited(_confirmClearDevices(pq: true)),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// RFC 6121 `<show/>` picker. The selected show is published by the view model.
class _PresencePicker extends StatefulWidget {
  const _PresencePicker({
    required this.accountId,
    required this.enabled,
    required this.onSelected,
  });

  final String accountId;
  final bool enabled;
  final Future<void> Function(PresenceShow show) onSelected;

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
                : () => unawaited(_set(show)),
          ),
      ],
    );
  }

  Future<void> _set(PresenceShow show) async {
    await widget.onSelected(show);
    if (mounted) setState(() => _current = show);
  }
}

/// Conversations `ChangePasswordActivity`: current password must match the
/// one stored for this account, and the new one must not be empty.
class _ChangePasswordDialog extends StatefulWidget {
  const _ChangePasswordDialog({required this.currentPassword});

  final String currentPassword;

  @override
  State<_ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<_ChangePasswordDialog> {
  final _current = TextEditingController();
  final _next = TextEditingController();
  String? _currentError;
  String? _nextError;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    super.dispose();
  }

  void _submit() {
    final l10n = context.l10n;
    final current = _current.text;
    final next = _next.text;
    String? currentError;
    String? nextError;
    if (current != widget.currentPassword) {
      currentError = l10n.currentPasswordWrong;
    }
    if (next.trim().isEmpty) {
      nextError = l10n.passwordShouldNotBeEmpty;
    }
    if (currentError != null || nextError != null) {
      setState(() {
        _currentError = currentError;
        _nextError = nextError;
      });
      return;
    }
    Navigator.pop(context, (current: current, next: next));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.changePassword),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _current,
            obscureText: true,
            autofocus: true,
            decoration: InputDecoration(
              labelText: l10n.currentPassword,
              errorText: _currentError,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _next,
            obscureText: true,
            decoration: InputDecoration(
              labelText: l10n.newPassword,
              errorText: _nextError,
            ),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        TextButton(onPressed: _submit, child: Text(l10n.changePassword)),
      ],
    );
  }
}
