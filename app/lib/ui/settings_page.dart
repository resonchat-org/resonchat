// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../net/app_network.dart';
import '../pq/liboqs_mlkem.dart';
import '../omemo/track.dart';
import '../state/providers.dart';
import '../xmpp/connection.dart';
import 'archive_page.dart';
import 'theme.dart';

/// App settings. Deliberately free of branding that would suggest any
/// affiliation with other messengers (docs/05 §6).
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  bool? _readReceipts;
  bool? _chatStates;
  bool _socks5Enabled = false;
  final _socks5Port = TextEditingController(text: '7890');

  @override
  void initState() {
    super.initState();
    final xmpp = ref.read(xmppServiceProvider);
    _readReceipts = xmpp.sendReadReceipts;
    _chatStates = xmpp.sendTypingNotifications;
    ref.read(databaseProvider).sendReadReceiptsEnabled().then((v) {
      if (mounted) setState(() => _readReceipts = v);
    });
    ref.read(databaseProvider).sendChatStatesEnabled().then((v) {
      if (mounted) setState(() => _chatStates = v);
    });
    _loadSocks5();
  }

  Future<void> _loadSocks5() async {
    final db = ref.read(databaseProvider);
    final enabled = await db.socks5ProxyEnabled();
    final port = await db.socks5ProxyPort();
    if (!mounted) return;
    setState(() {
      _socks5Enabled = enabled;
      _socks5Port.text = '$port';
    });
    appNetwork.config = Socks5ProxyConfig(
      enabled: enabled,
      host: await db.socks5ProxyHost(),
      port: port,
    );
  }

  @override
  void dispose() {
    _socks5Port.dispose();
    super.dispose();
  }

  Future<void> _applySocks5({bool? enabled, int? port}) async {
    final l10n = context.l10n;
    final nextEnabled = enabled ?? _socks5Enabled;
    final parsed = port ?? int.tryParse(_socks5Port.text.trim());
    if (parsed == null || parsed < 1 || parsed > 65535) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.socks5ProxyInvalidPort)),
      );
      return;
    }
    final db = ref.read(databaseProvider);
    final host = await db.socks5ProxyHost();
    await db.setSocks5ProxyEnabled(nextEnabled);
    await db.setSocks5ProxyPort(parsed);
    appNetwork.config = Socks5ProxyConfig(
      enabled: nextEnabled,
      host: host,
      port: parsed,
    );
    if (!mounted) return;
    setState(() {
      _socks5Enabled = nextEnabled;
      _socks5Port.text = '$parsed';
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.socks5ProxyApplied)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tg = context.tg;
    final l10n = context.l10n;
    final xmpp = ref.watch(xmppServiceProvider);
    final native = MlKem768Provider.instance.isNative;
    final readReceipts = _readReceipts ?? xmpp.sendReadReceipts;
    final chatStates = _chatStates ?? xmpp.sendTypingNotifications;
    final localeOverride = ref.watch(localeOverrideProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.settings)),
      body: ListView(
        children: [
          _header(tg, l10n.defaultEncryption),
          Consumer(
            builder: (context, ref, _) {
              final current =
                  ref.watch(globalTrackProvider).value ?? Track.standard;
              return Column(
                children: [
                  for (final track in Track.values)
                    RadioListTile<Track>(
                      value: track,
                      // ignore: deprecated_member_use
                      groupValue: current,
                      // ignore: deprecated_member_use
                      onChanged: (value) {
                        if (value != null) setGlobalTrack(ref, value);
                      },
                      title: Text(
                        '${track.label}  ${track.localizedDescription(l10n)}',
                      ),
                      secondary: Icon(
                        track.icon,
                        color: track == Track.none
                            ? tg.danger
                            : tg.accent,
                      ),
                    ),
                ],
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.archive_outlined),
            title: Text(l10n.archivedConversations),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const ArchivePage()),
            ),
          ),

          _header(tg, l10n.privacy),
          SwitchListTile(
            secondary: const Icon(Icons.done_all),
            title: Text(l10n.readReceipts),
            subtitle: Text(l10n.readReceiptsSummary),
            value: readReceipts,
            onChanged: (v) async {
              setState(() => _readReceipts = v);
              xmpp.sendReadReceipts = v;
              await ref.read(databaseProvider).setSendReadReceipts(v);
            },
          ),
          SwitchListTile(
            secondary: const Icon(Icons.edit_outlined),
            title: Text(l10n.typingNotifications),
            subtitle: Text(l10n.typingNotificationsSummary),
            value: chatStates,
            onChanged: (v) async {
              setState(() => _chatStates = v);
              xmpp.sendTypingNotifications = v;
              await ref.read(databaseProvider).setSendChatStates(v);
            },
          ),
          ListTile(
            leading: const Icon(Icons.language),
            title: Text(l10n.language),
            subtitle: Text(_languageLabel(l10n, localeOverride)),
            onTap: () => _pickLanguage(context, localeOverride),
          ),

          _header(tg, l10n.connection),
          // SOCKS5 is a TCP CONNECT proxy — browsers cannot use it.
          if (!kIsWeb) ...[
            SwitchListTile(
              secondary: const Icon(Icons.vpn_key_outlined),
              title: Text(l10n.socks5Proxy),
              subtitle: Text(l10n.socks5ProxySummary),
              value: _socks5Enabled,
              onChanged: (v) => _applySocks5(enabled: v),
            ),
            if (_socks5Enabled)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: TextField(
                  controller: _socks5Port,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: l10n.socks5ProxyPort,
                    helperText: l10n.socks5ProxyPortHint,
                    prefixText: '127.0.0.1:',
                  ),
                  onSubmitted: (_) => _applySocks5(),
                  onEditingComplete: () => _applySocks5(),
                ),
              ),
          ],
          ListTile(
            leading: const Icon(Icons.cloud_outlined),
            title: Text(l10n.status),
            subtitle: Text(_status(l10n, xmpp)),
            trailing: Icon(
              xmpp.state == XmppConnectionState.connected
                  ? Icons.check_circle
                  : Icons.error_outline,
              color: xmpp.state == XmppConnectionState.connected
                  ? tg.unreadBadge
                  : tg.danger,
              size: 20,
            ),
          ),
          ListTile(
            leading: const Icon(Icons.sync),
            title: Text(l10n.messageCarbons),
            subtitle: Text(
              xmpp.carbonsEnabled
                  ? l10n.messageCarbonsEnabled
                  : l10n.messageCarbonsDisabled,
            ),
          ),
          ListTile(
            leading: const Icon(Icons.archive_outlined),
            title: Text(l10n.messageArchiveMam),
            subtitle: Text(
              xmpp.mamAvailable
                  ? l10n.messageArchiveAvailable
                  : l10n.messageArchiveUnavailable,
            ),
          ),

          _header(tg, l10n.encryption),
          ListTile(
            leading: Icon(
              Icons.bolt,
              color: xmpp.bTrackReady ? tg.accent : tg.textSecondary,
            ),
            title: Text(l10n.postQuantumTrack),
            subtitle: Text(
              xmpp.bTrackReady
                  ? l10n.postQuantumReady
                  : l10n.postQuantumNotReady,
            ),
          ),
          ListTile(
            leading: const Icon(Icons.memory),
            title: Text(l10n.postQuantumBackend),
            subtitle: Text(
              native ? l10n.backendNative : l10n.backendDart,
            ),
            trailing: Text(
              native ? 'native' : 'dart',
              style: TextStyle(color: tg.textSecondary, fontSize: 12),
            ),
          ),

          _header(tg, l10n.about),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            child: Text(
              l10n.aboutBody,
              style: const TextStyle(fontSize: 13, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }

  String _languageLabel(AppLocalizations l10n, Locale? override) {
    if (override == null) return l10n.languageSystem;
    if (override.languageCode == 'zh') return l10n.languageChineseSimplified;
    return l10n.languageEnglish;
  }

  Future<void> _pickLanguage(BuildContext context, Locale? current) async {
    final l10n = context.l10n;
    final chosen = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(l10n.languageSystem),
              trailing: current == null ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(ctx, ''),
            ),
            ListTile(
              title: Text(l10n.languageEnglish),
              trailing: current?.languageCode == 'en'
                  ? const Icon(Icons.check)
                  : null,
              onTap: () => Navigator.pop(ctx, 'en'),
            ),
            ListTile(
              title: Text(l10n.languageChineseSimplified),
              trailing: current?.languageCode == 'zh'
                  ? const Icon(Icons.check)
                  : null,
              onTap: () => Navigator.pop(ctx, 'zh'),
            ),
          ],
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    await ref.read(localeOverrideProvider.notifier).setOverride(
          localeFromPref(chosen.isEmpty ? null : chosen),
        );
  }

  static Widget _header(TgColors tg, String title) => Padding(
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

  static String _status(AppLocalizations l10n, XmppService xmpp) =>
      switch (xmpp.state) {
        XmppConnectionState.connected => l10n.statusConnected,
        XmppConnectionState.connecting => l10n.statusConnecting,
        XmppConnectionState.disconnected =>
          xmpp.lastError ?? l10n.statusDisconnected,
      };
}
