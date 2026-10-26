// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Invite into an existing room: pick roster contacts (same list as creating
// a private group) and/or type a bare JID. Bottom sheet, not a dialog.

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:resonchat/account/resolve.dart';
import 'package:resonchat/l10n/l10n.dart';
import 'package:resonchat/state/providers.dart';
import 'package:resonchat/ui/contacts/contacts_match.dart';
import 'package:resonchat/ui/theme.dart';

/// `true` when every invite was accepted by the server, `false` when any
/// failed, `null` when the sheet was dismissed.
Future<bool?> showInviteMemberSheet(
  BuildContext context, {
  required String chatJid,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _InviteMemberSheet(chatJid: chatJid),
  );
}

class _InviteMemberSheet extends ConsumerStatefulWidget {
  const _InviteMemberSheet({required this.chatJid});

  final String chatJid;

  @override
  ConsumerState<_InviteMemberSheet> createState() => _InviteMemberSheetState();
}

class _InviteMemberSheetState extends ConsumerState<_InviteMemberSheet> {
  final _jid = TextEditingController();
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
    _jid.dispose();
    super.dispose();
  }

  Future<void> _loadRoster() async {
    final resolved = resolveChatKey(widget.chatJid);
    final db = resolved.session.db;
    final rows = await db.allRosterEntries();
    if (!mounted) return;
    final mine = resolved.session.account.bareJid.toLowerCase();
    final room = resolved.jid.toLowerCase();
    final present = <String>{
      for (final o
          in ref.read(roomStateProvider(widget.chatJid)).value?.occupants ??
              const [])
        if (o.realJid != null && o.realJid!.trim().isNotEmpty)
          o.realJid!.trim().toLowerCase(),
    };
    setState(() {
      _roster = [
        for (final r in rows)
          if (r.jid.toLowerCase() != mine &&
              r.jid.toLowerCase() != room &&
              !present.contains(r.jid.toLowerCase()) &&
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

  Future<void> _send() async {
    final l10n = context.l10n;
    final typed = _jid.text.trim();
    final targets = {..._selected};
    if (typed.isNotEmpty) {
      final jid = completeJidCandidate(typed);
      if (jid == null) {
        setState(() => _error = l10n.invalidJid);
        return;
      }
      targets.add(jid);
    }
    if (targets.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final xmpp = resolveChatKey(widget.chatJid).session.xmpp;
    final roomJid = resolveChatKey(widget.chatJid).jid;
    var ok = true;
    for (final jid in targets) {
      if (!await xmpp.inviteToRoom(roomJid, jid)) ok = false;
    }
    if (!mounted) return;
    Navigator.of(context).pop(ok);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tg = context.tg;
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    final canSend =
        !_busy && (_selected.isNotEmpty || _jid.text.trim().isNotEmpty);
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.inviteMember,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _jid,
                enabled: !_busy,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(hintText: l10n.inviteMemberHint),
                onChanged: (_) => setState(() => _error = null),
                onSubmitted: (_) => unawaited(_send()),
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
                onPressed: canSend ? () => unawaited(_send()) : null,
                child: Text(l10n.inviteMember),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
