// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Per-account XEP-0171 translation provider: discover on the server, pick, or
// type a provider JID (bare bot, domain component, or full — XEP §4.2.2).

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:resonchat/account/account_hub.dart';
import 'package:resonchat/l10n/l10n.dart';
import 'package:resonchat/translate/remote_translation.dart';
import 'package:resonchat/ui/theme.dart';
import 'package:resonchat/xmpp/connection.dart';
import 'package:resonchat/xmpp/jid_input.dart';

/// XEP-0171 provider address: Conversations `ofUserInput` rules (resource optional).
bool looksLikeTranslationProviderJid(String raw) => jidOfUserInput(raw) != null;

/// Bottom sheet: set this account's XEP-0171 translation provider JID.
Future<void> showTranslationProviderSheet(
  BuildContext context, {
  required String accountId,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
      child: _TranslationProviderSheet(accountId: accountId),
    ),
  );
}

class _TranslationProviderSheet extends StatefulWidget {
  const _TranslationProviderSheet({required this.accountId});

  final String accountId;

  @override
  State<_TranslationProviderSheet> createState() =>
      _TranslationProviderSheetState();
}

class _TranslationProviderSheetState extends State<_TranslationProviderSheet> {
  final _jid = TextEditingController();
  bool _ready = false;
  bool _saving = false;
  bool _discovering = false;
  List<TranslationProviderCandidate>? _candidates;

  AccountSession? get _session => accountHub.session(widget.accountId);

  /// Empty clears the pref; non-empty must pass [jidOfUserInput].
  bool get _canSave =>
      !_saving &&
      jidInputOk(
        _jid.text,
        bareOnly: false,
        requireLocalpart: false,
        allowEmpty: true,
      );

  @override
  void initState() {
    super.initState();
    _jid.addListener(() => setState(() {}));
    unawaited(_load());
  }

  Future<void> _load() async {
    final session = _session;
    final stored = session == null
        ? null
        : await session.db.translationProviderJid();
    if (!mounted) return;
    setState(() {
      _jid.text = stored ?? '';
      _ready = true;
    });
  }

  Future<void> _save({bool clear = false}) async {
    final l10n = context.l10n;
    final session = _session;
    if (session == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.notConnectedTryAgain)));
      return;
    }
    final typed = clear ? '' : _jid.text.trim();
    final normalized = typed.isEmpty ? null : jidOfUserInput(typed);
    if (typed.isNotEmpty && normalized == null) {
      return;
    }
    setState(() => _saving = true);
    await session.db.setTranslationProviderJid(normalized);
    session.xmpp.clearRemoteTranslationCache();
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          normalized == null
              ? l10n.translationProviderCleared
              : l10n.translationProviderSaved,
        ),
      ),
    );
    Navigator.of(context).pop();
  }

  Future<void> _discover() async {
    final l10n = context.l10n;
    final session = _session;
    if (session == null ||
        session.xmpp.state != XmppConnectionState.connected) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.notConnectedTryAgain)));
      return;
    }
    setState(() {
      _discovering = true;
      _candidates = null;
    });
    final found = await session.xmpp.discoverTranslationProviders();
    if (!mounted) return;
    setState(() {
      _discovering = false;
      _candidates = found ?? const [];
    });
    if (found == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.notConnectedTryAgain)));
      return;
    }
    if (found.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.translationProviderDiscoverEmpty)),
      );
    }
  }

  void _pick(TranslationProviderCandidate candidate) {
    setState(() => _jid.text = candidate.jid.toString());
  }

  @override
  void dispose() {
    _jid.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    if (!_ready) {
      return const SizedBox(
        height: 160,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final candidates = _candidates;
    final typed = _jid.text.trim();
    final jidError = typed.isNotEmpty && jidOfUserInput(typed) == null
        ? l10n.invalidJid
        : null;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  l10n.translationProvider,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  l10n.translationProviderSummary,
                  style: context.appText.helper,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: TextField(
                  controller: _jid,
                  enabled: !_saving,
                  autocorrect: false,
                  enableSuggestions: false,
                  keyboardType: TextInputType.emailAddress,
                  decoration: InputDecoration(
                    labelText: l10n.translationProviderJid,
                    hintText: l10n.translationProviderJidHint,
                    errorText: jidError,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                child: FilledButton.tonal(
                  onPressed: _discovering || _saving
                      ? null
                      : () => unawaited(_discover()),
                  child: _discovering
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(l10n.translationProviderDiscover),
                ),
              ),
              if (candidates != null && candidates.isNotEmpty) ...[
                const SizedBox(height: 8),
                for (final c in candidates)
                  ListTile(
                    leading: const Icon(Icons.translate),
                    title: Text(
                      c.name?.trim().isNotEmpty == true
                          ? c.name!
                          : c.jid.toString(),
                    ),
                    subtitle: c.name?.trim().isNotEmpty == true
                        ? Text(c.jid.toString())
                        : null,
                    onTap: _saving ? null : () => _pick(c),
                  ),
              ],
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: FilledButton(
                  onPressed: _canSave ? () => unawaited(_save()) : null,
                  child: Text(l10n.save),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: TextButton(
                  onPressed: _saving
                      ? null
                      : () => unawaited(_save(clear: true)),
                  child: Text(l10n.clear),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
