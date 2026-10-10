// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Edit own nickname (XEP-0172) and avatar (XEP-0084), Conversations
// EditAccountActivity + PublishProfilePictureActivity.

import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../account/account_hub.dart';
import '../../l10n/l10n.dart';
import '../../state/providers.dart';
import '../../store/account_store.dart';
import '../../xmpp/avatar.dart';
import '../contact_avatar.dart';
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
  }

  @override
  void dispose() {
    _nick.dispose();
    super.dispose();
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
            ],
          ),
        );
      },
    );
  }
}
