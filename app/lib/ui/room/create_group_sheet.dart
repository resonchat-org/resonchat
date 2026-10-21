// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Create private group / public channel (Conversations CreatePrivateGroupChatDialog
// + CreatePublicChannelDialog).

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:resonchat/account/account_hub.dart';
import 'package:resonchat/account/chat_ref.dart';
import 'package:resonchat/l10n/l10n.dart';
import 'package:resonchat/state/providers.dart';
import 'package:resonchat/ui/home/open_chat.dart';
import 'package:resonchat/ui/theme.dart';
import 'package:resonchat/xmpp/muc/muc_create.dart';

/// Conversations “Create private group chat”.
Future<void> showCreatePrivateGroupSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const _CreatePrivateGroupSheet(),
  );
}

/// Conversations “Create public channel”.
Future<void> showCreatePublicChannelSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const _CreatePublicChannelSheet(),
  );
}

class _CreatePrivateGroupSheet extends ConsumerStatefulWidget {
  const _CreatePrivateGroupSheet();

  @override
  ConsumerState<_CreatePrivateGroupSheet> createState() =>
      _CreatePrivateGroupSheetState();
}

class _CreatePrivateGroupSheetState
    extends ConsumerState<_CreatePrivateGroupSheet> {
  final _name = TextEditingController();
  final _selected = <String>{};
  List<({String jid, String label})> _roster = const [];
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_loadRoster());
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _loadRoster() async {
    final db = accountHub.primarySession?.db;
    if (db == null) return;
    final rows = await db.allRosterEntries();
    if (!mounted) return;
    final mine = accountHub.primarySession?.account.bareJid;
    setState(() {
      _roster = [
        for (final r in rows)
          if (r.jid != mine &&
              (r.subscription == 'both' ||
                  r.subscription == 'to' ||
                  r.subscription == 'from'))
            (
              jid: r.jid,
              label: r.name.trim().isNotEmpty ? r.name.trim() : r.jid,
            ),
      ]..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
    });
  }

  Future<void> _create() async {
    final l10n = context.l10n;
    setState(() {
      _busy = true;
      _error = null;
    });
    final xmpp = ref.read(xmppServiceProvider);
    final result = await xmpp.createPrivateGroupChat(
      name: _name.text.trim(),
      inviteeJids: _selected.toList(),
    );
    if (!mounted) return;
    if (!result.ok) {
      setState(() {
        _busy = false;
        _error = _describeCreateError(l10n, result.error);
      });
      return;
    }
    await _persistAndOpen(result);
  }

  Future<void> _persistAndOpen(CreateRoomResult result) async {
    final db = ref.read(databaseProvider);
    final xmpp = ref.read(xmppServiceProvider);
    final roomJid = result.roomJid!;
    await db.upsertChat(
      roomJid,
      isGroup: true,
      mucNick: result.nick,
      title: result.title,
      mucPrivateNonAnonymous: result.privateNonAnonymous,
    );
    await xmpp.removeFromRosterIfPresent(roomJid);
    unawaited(
      xmpp.publishConferenceBookmark(
        roomJid: roomJid,
        name: result.title,
        nick: result.nick,
      ),
    );
    if (!mounted) return;
    Navigator.of(context).pop();
    final accountId = accountHub.primarySession?.account.id;
    final chatKey = accountId == null
        ? roomJid
        : ChatRef(accountId: accountId, jid: roomJid).key;
    openChat(context, chatKey);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tg = context.tg;
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 16, 20, bottom + 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.createPrivateGroup,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _name,
            enabled: !_busy,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              labelText: l10n.groupChatName,
              hintText: l10n.groupChatNameOptional,
            ),
            onSubmitted: (_) => unawaited(_create()),
          ),
          if (_roster.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              l10n.chooseParticipants,
              style: TextStyle(color: tg.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _roster.length,
                itemBuilder: (context, i) {
                  final c = _roster[i];
                  final on = _selected.contains(c.jid);
                  return CheckboxListTile(
                    dense: true,
                    value: on,
                    title: Text(
                      c.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: c.label == c.jid
                        ? null
                        : Text(
                            c.jid,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                    onChanged: _busy
                        ? null
                        : (v) {
                            setState(() {
                              if (v == true) {
                                _selected.add(c.jid);
                              } else {
                                _selected.remove(c.jid);
                              }
                            });
                          },
                  );
                },
              ),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: TextStyle(color: tg.danger, fontSize: 13)),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : () => unawaited(_create()),
            child: Text(_busy ? l10n.creatingGroup : l10n.create),
          ),
        ],
      ),
    );
  }
}

class _CreatePublicChannelSheet extends ConsumerStatefulWidget {
  const _CreatePublicChannelSheet();

  @override
  ConsumerState<_CreatePublicChannelSheet> createState() =>
      _CreatePublicChannelSheetState();
}

class _CreatePublicChannelSheetState
    extends ConsumerState<_CreatePublicChannelSheet> {
  final _name = TextEditingController();
  final _jid = TextEditingController();
  bool _busy = false;
  String? _error;
  var _jidTouched = false;

  @override
  void initState() {
    super.initState();
    unawaited(_suggestJid());
  }

  @override
  void dispose() {
    _name.dispose();
    _jid.dispose();
    super.dispose();
  }

  Future<void> _suggestJid() async {
    final xmpp = ref.read(xmppServiceProvider);
    final host = await xmpp.discoverMucServiceHost();
    if (!mounted || host == null || _jidTouched) return;
    final local = pronounceableRoomLocalpart();
    setState(() => _jid.text = '$local@$host');
  }

  Future<void> _create() async {
    final l10n = context.l10n;
    final address = _jid.text.trim();
    if (address.isEmpty || !address.contains('@')) {
      setState(() => _error = l10n.createGroupInvalidJid);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final xmpp = ref.read(xmppServiceProvider);
    final result = await xmpp.createPublicChannel(
      roomJid: address,
      name: _name.text.trim(),
    );
    if (!mounted) return;
    if (!result.ok) {
      setState(() {
        _busy = false;
        _error = _describeCreateError(l10n, result.error);
      });
      return;
    }
    final db = ref.read(databaseProvider);
    await db.upsertChat(
      result.roomJid!,
      isGroup: true,
      mucNick: result.nick,
      title: result.title,
      mucPrivateNonAnonymous: result.privateNonAnonymous,
    );
    await xmpp.removeFromRosterIfPresent(result.roomJid!);
    unawaited(
      xmpp.publishConferenceBookmark(
        roomJid: result.roomJid!,
        name: result.title,
        nick: result.nick,
      ),
    );
    if (!mounted) return;
    Navigator.of(context).pop();
    final accountId = accountHub.primarySession?.account.id;
    final chatKey = accountId == null
        ? result.roomJid!
        : ChatRef(accountId: accountId, jid: result.roomJid!).key;
    openChat(context, chatKey);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tg = context.tg;
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 16, 20, bottom + 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.createPublicChannel,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _name,
            enabled: !_busy,
            decoration: InputDecoration(labelText: l10n.channelName),
            onChanged: (v) {
              if (_jidTouched) return;
              // Keep suggested localpart; only refresh when empty.
            },
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _jid,
            enabled: !_busy,
            decoration: InputDecoration(
              labelText: l10n.channelAddress,
              hintText: l10n.channelAddressHint,
            ),
            onChanged: (_) => _jidTouched = true,
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: TextStyle(color: tg.danger, fontSize: 13)),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : () => unawaited(_create()),
            child: Text(_busy ? l10n.creatingGroup : l10n.create),
          ),
        ],
      ),
    );
  }
}

String _describeCreateError(AppLocalizations l10n, String? code) {
  return switch (code) {
    'no_muc_service' => l10n.createGroupNoMucService,
    'invalid_jid' => l10n.createGroupInvalidJid,
    'no_nick' => l10n.nicknameRequired,
    _ => l10n.createGroupFailed(code ?? ''),
  };
}
