// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../net/app_network.dart';
import '../../pq/liboqs_mlkem.dart';
import '../../omemo/track.dart';
import '../../state/providers.dart';
import '../../xmpp/connection.dart';
import '../archive/archive_page.dart';
import '../theme.dart';
import 'settings_viewmodel.dart';
import 'socks5_proxy_sheet.dart';

/// App settings. Deliberately free of branding that would suggest any
/// affiliation with other messengers (docs/05 §6).
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  @override
  Widget build(BuildContext context) {
    final tg = context.tg;
    final l10n = context.l10n;
    final settings = ref.watch(settingsViewModelProvider);
    final xmpp = ref.watch(xmppServiceProvider);
    final native = MlKem768Provider.instance.isNative;
    final readReceipts = settings.readReceipts ?? xmpp.sendReadReceipts;
    final chatStates = settings.chatStates ?? xmpp.sendTypingNotifications;
    final localeOverride = ref.watch(localeOverrideProvider);
    final vm = ref.read(settingsViewModelProvider.notifier);

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
                        if (value != null)
                          unawaited(vm.setGlobalEncryption(value));
                      },
                      title: Text(
                        '${track.label}  ${track.localizedDescription(l10n)}',
                      ),
                      secondary: Icon(
                        track.icon,
                        color: track == Track.none ? tg.danger : tg.accent,
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
            onChanged: (v) => unawaited(vm.setReadReceipts(v)),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.edit_outlined),
            title: Text(l10n.typingNotifications),
            subtitle: Text(l10n.typingNotificationsSummary),
            value: chatStates,
            onChanged: (v) => unawaited(vm.setChatStates(v)),
          ),
          ListTile(
            leading: const Icon(Icons.language),
            title: Text(l10n.language),
            subtitle: Text(_languageLabel(l10n, localeOverride)),
            onTap: () => _pickLanguage(context, localeOverride),
          ),

          _header(tg, l10n.connection),
          // SOCKS5 is a TCP CONNECT proxy — browsers cannot use it.
          if (!kIsWeb)
            ListTile(
              leading: Icon(
                Icons.vpn_key_outlined,
                color: appNetwork.config.enabled ? tg.accent : null,
              ),
              title: Text(l10n.socks5Proxy),
              subtitle: Text(
                appNetwork.config.enabled
                    ? '${appNetwork.config.host}:${appNetwork.config.port}'
                    : l10n.socks5ProxySummary,
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                await showSocks5ProxySheet(context, ref);
                if (mounted) setState(() {});
              },
            ),
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
            subtitle: Text(native ? l10n.backendNative : l10n.backendDart),
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
    await ref
        .read(localeOverrideProvider.notifier)
        .setOverride(localeFromPref(chosen.isEmpty ? null : chosen));
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
