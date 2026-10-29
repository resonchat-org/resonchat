// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Create private group / public channel (Conversations CreatePrivateGroupChatDialog
// + CreatePublicChannelDialog).

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:resonchat/account/account_hub.dart';
import 'package:resonchat/account/chat_ref.dart';
import 'package:resonchat/l10n/l10n.dart';
import 'package:resonchat/ui/accounts/account_action_picker.dart';
import 'package:resonchat/ui/home/open_chat.dart';
import 'package:resonchat/ui/theme.dart';
import 'package:resonchat/xmpp/jid_input.dart';
import 'package:resonchat/xmpp/muc/muc_create.dart';

/// Conversations “Create private group chat”.
Future<void> showCreatePrivateGroupSheet(
  BuildContext context, {
  String? accountId,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _CreatePrivateGroupSheet(initialAccountId: accountId),
  );
}

/// Conversations “Create public channel”.
Future<void> showCreatePublicChannelSheet(
  BuildContext context, {
  String? accountId,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _CreatePublicChannelSheet(initialAccountId: accountId),
  );
}

class _CreatePrivateGroupSheet extends ConsumerStatefulWidget {
  const _CreatePrivateGroupSheet({this.initialAccountId});

  final String? initialAccountId;

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
  String? _accountId;

  @override
  void initState() {
    super.initState();
    _accountId = defaultActionAccountId(preferred: widget.initialAccountId);
    unawaited(_loadRoster());
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _loadRoster() async {
    final session = _accountId == null ? null : accountHub.session(_accountId!);
    final db = session?.db;
    if (db == null) {
      if (mounted) setState(() => _roster = const []);
      return;
    }
    final rows = await db.allRosterEntries();
    if (!mounted) return;
    final mine = session?.account.bareJid;
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
    final session = _accountId == null ? null : accountHub.session(_accountId!);
    if (session == null) {
      setState(() => _error = l10n.noAccountReady);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await session.xmpp.createPrivateGroupChat(
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
    await _persistAndOpen(session, result);
  }

  Future<void> _persistAndOpen(
    AccountSession session,
    CreateRoomResult result,
  ) async {
    final xmpp = session.xmpp;
    final db = session.db;
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
    openChat(context, ChatRef(accountId: session.account.id, jid: roomJid).key);
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
          AccountActionPicker(
            selectedId: _accountId,
            enabled: !_busy,
            onChanged: (id) {
              setState(() {
                _accountId = id;
                _selected.clear();
              });
              unawaited(_loadRoster());
            },
          ),
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
  const _CreatePublicChannelSheet({this.initialAccountId});

  final String? initialAccountId;

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
  String? _accountId;

  @override
  void initState() {
    super.initState();
    _accountId = defaultActionAccountId(preferred: widget.initialAccountId);
    _jid.addListener(() => setState(() {}));
    unawaited(_suggestJid());
  }

  @override
  void dispose() {
    _name.dispose();
    _jid.dispose();
    super.dispose();
  }

  Future<void> _suggestJid() async {
    final session = _accountId == null ? null : accountHub.session(_accountId!);
    if (session == null) return;
    final host = await session.xmpp.discoverMucServiceHost();
    if (!mounted || host == null || _jidTouched) return;
    final local = pronounceableRoomLocalpart();
    setState(() => _jid.text = '$local@$host');
  }

  Future<void> _create() async {
    final l10n = context.l10n;
    final address = completeJidCandidate(_jid.text);
    if (address == null) {
      setState(() => _error = l10n.createGroupInvalidJid);
      return;
    }
    final session = _accountId == null ? null : accountHub.session(_accountId!);
    if (session == null) {
      setState(() => _error = l10n.noAccountReady);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final xmpp = session.xmpp;
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
    final db = session.db;
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
    openChat(
      context,
      ChatRef(accountId: session.account.id, jid: result.roomJid!).key,
    );
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
          AccountActionPicker(
            selectedId: _accountId,
            enabled: !_busy,
            onChanged: (id) {
              setState(() {
                _accountId = id;
                _jidTouched = false;
              });
              unawaited(_suggestJid());
            },
          ),
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
              errorText:
                  _jid.text.trim().isNotEmpty &&
                      completeJidCandidate(_jid.text) == null
                  ? l10n.invalidJid
                  : null,
            ),
            onChanged: (_) => _jidTouched = true,
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: TextStyle(color: tg.danger, fontSize: 13)),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy || completeJidCandidate(_jid.text) == null
                ? null
                : () => unawaited(_create()),
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
