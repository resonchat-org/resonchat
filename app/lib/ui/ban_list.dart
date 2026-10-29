// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Shared row + add-JID dialog for account blocklist and MUC outcasts.

import 'package:flutter/material.dart';

import 'package:resonchat/l10n/l10n.dart';
import 'package:resonchat/ui/theme.dart';
import 'package:resonchat/xmpp/jid_input.dart';

/// One ban/block row: JID, optional detail (e.g. ban reason), unlock action.
class BanListTile extends StatelessWidget {
  const BanListTile({
    super.key,
    required this.jid,
    required this.removeTooltip,
    required this.onRemove,
    this.detail,
    this.enabled = true,
  });

  final String jid;
  final String? detail;
  final String removeTooltip;
  final VoidCallback? onRemove;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final tg = context.tg;
    final d = detail?.trim();
    return ListTile(
      leading: Icon(Icons.block, color: tg.danger),
      title: Text(jid),
      subtitle: d != null && d.isNotEmpty ? Text(d) : null,
      trailing: IconButton(
        tooltip: removeTooltip,
        onPressed: enabled ? onRemove : null,
        icon: const Icon(Icons.lock_open),
      ),
    );
  }
}

/// Add a bare JID; set [askReason] for MUC bans.
Future<({String jid, String reason})?> showAddBanJidDialog(
  BuildContext context, {
  required String title,
  required String confirmLabel,
  bool askReason = false,
}) {
  return showDialog<({String jid, String reason})>(
    context: context,
    builder: (ctx) => _AddBanJidDialog(
      title: title,
      confirmLabel: confirmLabel,
      askReason: askReason,
    ),
  );
}

class _AddBanJidDialog extends StatefulWidget {
  const _AddBanJidDialog({
    required this.title,
    required this.confirmLabel,
    required this.askReason,
  });

  final String title;
  final String confirmLabel;
  final bool askReason;

  @override
  State<_AddBanJidDialog> createState() => _AddBanJidDialogState();
}

class _AddBanJidDialogState extends State<_AddBanJidDialog> {
  final _jid = TextEditingController();
  final _reason = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _jid.dispose();
    _reason.dispose();
    super.dispose();
  }

  void _submit() {
    final l10n = context.l10n;
    final jid = completeJidCandidate(_jid.text);
    if (jid == null) {
      setState(() => _error = l10n.invalidJid);
      return;
    }
    Navigator.pop(context, (
      jid: jid.toLowerCase(),
      reason: _reason.text.trim(),
    ));
  }

  bool get _canSubmit => completeJidCandidate(_jid.text) != null;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final typed = _jid.text.trim();
    final showError = typed.isNotEmpty && completeJidCandidate(typed) == null;
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _jid,
            autofocus: true,
            decoration: InputDecoration(
              labelText: l10n.jid,
              hintText: 'user@example.org',
              errorText: _error ?? (showError ? l10n.invalidJid : null),
            ),
            keyboardType: TextInputType.emailAddress,
            textInputAction: widget.askReason
                ? TextInputAction.next
                : TextInputAction.done,
            onSubmitted: (_) {
              if (!widget.askReason && _canSubmit) _submit();
            },
            onChanged: (_) => setState(() => _error = null),
          ),
          if (widget.askReason) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _reason,
              decoration: InputDecoration(labelText: l10n.banReasonOptional),
              textInputAction: TextInputAction.done,
              onSubmitted: (_) {
                if (_canSubmit) _submit();
              },
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        TextButton(
          onPressed: _canSubmit ? _submit : null,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
