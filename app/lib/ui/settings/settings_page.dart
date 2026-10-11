// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../net/app_network.dart';
import '../../crypto/omemo/track.dart';
import '../../security/app_lock.dart';
import '../../state/providers.dart';
import '../../xmpp/message_expiry.dart';
import '../accent_theme.dart';
import '../archive/archive_page.dart';
import '../theme.dart';
import 'app_lock_pin_sheet.dart';
import 'settings_viewmodel.dart';
import 'socks5_proxy_sheet.dart';
import 'translation_settings_sheet.dart';
import '../../translate/translation_engine.dart';
import '../../translate/translation_prefs.dart';
import '../../untracker/prefs.dart';
import '../../xmpp/channel_discovery.dart';

/// App settings. Deliberately free of branding that would suggest any
/// affiliation with other messengers (docs/05 §6).
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  TranslationPrefs? _translationPrefs;
  ChannelDiscoveryMethod _channelMethod = ChannelDiscoveryMethod.jabberNetwork;
  bool _removeTrackingEnabled = false;

  @override
  void initState() {
    super.initState();
    unawaited(_reloadTranslationPrefs());
    unawaited(_reloadChannelMethod());
    unawaited(_reloadRemoveTracking());
  }

  Future<void> _reloadTranslationPrefs() async {
    final prefs = await TranslationPrefs.load();
    if (!mounted) return;
    setState(() => _translationPrefs = prefs);
  }

  Future<void> _reloadChannelMethod() async {
    final method = await loadChannelDiscoveryMethod();
    if (!mounted) return;
    setState(() => _channelMethod = method);
  }

  Future<void> _reloadRemoveTracking() async {
    final enabled = await loadRemoveTrackingEnabled();
    if (!mounted) return;
    setState(() => _removeTrackingEnabled = enabled);
  }

  Future<void> _setRemoveTracking(bool enabled) async {
    await saveRemoveTrackingEnabled(enabled);
    if (!mounted) return;
    setState(() => _removeTrackingEnabled = enabled);
  }

  @override
  Widget build(BuildContext context) {
    final tg = context.tg;
    final l10n = context.l10n;
    final settings = ref.watch(settingsViewModelProvider);
    final xmpp = ref.watch(xmppServiceProvider);
    final readReceipts = settings.readReceipts ?? xmpp.sendReadReceipts;
    final chatStates = settings.chatStates ?? xmpp.sendTypingNotifications;
    final localeOverride = ref.watch(localeOverrideProvider);
    final vm = ref.read(settingsViewModelProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.settings)),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.archive_outlined),
            title: Text(l10n.archivedConversations),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const ArchivePage()),
            ),
          ),

          // Conversations: Interface (theme / UI) is separate from Privacy.
          _header(tg, l10n.interface),
          Consumer(
            builder: (context, ref, _) {
              final pref = ref.watch(accentPreferenceProvider);
              final scheme = Theme.of(context).colorScheme;
              final swatch = pref.useDynamic
                  ? scheme.primary
                  : pref.fixed.swatch;
              final subtitle = pref.useDynamic
                  ? l10n.themeColorDynamic
                  : '${l10n.themeColorFixed} · ${pref.fixed.stored}';
              return ListTile(
                leading: Icon(Icons.palette_outlined, color: swatch),
                title: Text(l10n.themeColor),
                subtitle: Text(subtitle),
                trailing: pref.useDynamic
                    ? _DynamicAccentDot(color: swatch)
                    : _AccentDot(color: swatch),
                onTap: () => unawaited(_pickAccent(context, pref)),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.language),
            title: Text(l10n.language),
            subtitle: Text(_languageLabel(l10n, localeOverride)),
            onTap: () => _pickLanguage(context, localeOverride),
          ),

          _header(tg, l10n.privacy),
          ListenableBuilder(
            listenable: AppLock.instance,
            builder: (context, _) {
              final lock = AppLock.instance;
              return SwitchListTile(
                secondary: const Icon(Icons.visibility_off_outlined),
                title: Text(l10n.appLock),
                subtitle: Text(l10n.appLockSummary),
                value: lock.enabled && lock.hasPassword,
                onChanged: (v) => unawaited(_toggleAppLock(v)),
              );
            },
          ),
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
            leading: const Icon(Icons.auto_delete_outlined),
            title: Text(l10n.automaticMessageDeletion),
            subtitle: Text(
              '${_deletionLabel(l10n, settings.automaticDeletion)} · '
              '${l10n.automaticMessageDeletionSummary}',
            ),
            onTap: () => unawaited(
              _pickAutomaticDeletion(context, settings.automaticDeletion, vm),
            ),
          ),
          Consumer(
            builder: (context, ref, _) {
              final current =
                  ref.watch(globalTrackProvider).value ?? Track.standard;
              return ListTile(
                leading: Icon(
                  Icons.lock_outline,
                  color: current == Track.none ? tg.danger : null,
                ),
                title: Text(l10n.defaultEncryption),
                subtitle: Text(current.localizedShortLabel(l10n)),
                onTap: () =>
                    unawaited(_pickDefaultEncryption(context, current, vm)),
              );
            },
          ),
          SwitchListTile(
            secondary: const Icon(Icons.link_off_outlined),
            title: Text(l10n.removeTracking),
            subtitle: Text(l10n.removeTrackingSummary),
            value: _removeTrackingEnabled,
            onChanged: (v) => unawaited(_setRemoveTracking(v)),
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
          Builder(
            builder: (context) {
              final prefs = _translationPrefs;
              final subtitle = prefs == null
                  ? l10n.translationSummary
                  : prefs.engine == TranslationEngineId.deepL
                  ? (prefs.apiKey.trim().isEmpty
                        ? l10n.translationSummary
                        : l10n.translationDeepL)
                  : (prefs.baseUrl.trim().isEmpty
                        ? l10n.translationSummary
                        : prefs.baseUrl.trim());
              return ListTile(
                leading: const Icon(Icons.translate),
                title: Text(l10n.translation),
                subtitle: Text(subtitle),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  await showTranslationSettingsSheet(context);
                  await _reloadTranslationPrefs();
                },
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.travel_explore_outlined),
            title: Text(l10n.channelDiscoveryMethod),
            subtitle: Text(
              _channelMethod == ChannelDiscoveryMethod.localServer
                  ? l10n.channelDiscoveryLocalServer
                  : l10n.channelDiscoveryJabberNetwork,
            ),
            onTap: () => unawaited(_pickChannelDiscoveryMethod()),
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

  Future<void> _toggleAppLock(bool enable) async {
    if (!enable) {
      await AppLock.instance.clearPassword();
      return;
    }
    if (!mounted) return;
    final pin = await showAppLockPinSheet(context);
    if (pin == null || !mounted) return;
    await AppLock.instance.setPassword(pin);
    await AppLock.instance.setEnabled(true);
    // Stay in the real UI after configuring (Amarok unlock-after-set).
    AppLock.instance.unlock();
  }

  String _languageLabel(AppLocalizations l10n, Locale? override) {
    if (override == null) return l10n.languageSystem;
    if (override.languageCode == 'zh') return l10n.languageChineseSimplified;
    return l10n.languageEnglish;
  }

  String _deletionLabel(
    AppLocalizations l10n,
    AutomaticMessageDeletion value,
  ) => switch (value) {
    AutomaticMessageDeletion.never => l10n.automaticMessageDeletionNever,
    AutomaticMessageDeletion.oneDay => l10n.automaticMessageDeletionOneDay,
    AutomaticMessageDeletion.oneWeek => l10n.automaticMessageDeletionOneWeek,
    AutomaticMessageDeletion.thirtyDays =>
      l10n.automaticMessageDeletionThirtyDays,
    AutomaticMessageDeletion.sixMonths =>
      l10n.automaticMessageDeletionSixMonths,
  };

  Future<void> _pickChannelDiscoveryMethod() async {
    final l10n = context.l10n;
    final chosen = await showModalBottomSheet<ChannelDiscoveryMethod>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                l10n.channelDiscoverySummary,
                style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            for (final method in ChannelDiscoveryMethod.values)
              ListTile(
                title: Text(
                  method == ChannelDiscoveryMethod.localServer
                      ? l10n.channelDiscoveryLocalServer
                      : l10n.channelDiscoveryJabberNetwork,
                ),
                trailing: method == _channelMethod
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => Navigator.pop(ctx, method),
              ),
          ],
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    await saveChannelDiscoveryMethod(chosen);
    setState(() => _channelMethod = chosen);
  }

  Future<void> _pickAutomaticDeletion(
    BuildContext context,
    AutomaticMessageDeletion current,
    SettingsViewModel vm,
  ) async {
    final l10n = context.l10n;
    final chosen = await showModalBottomSheet<AutomaticMessageDeletion>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final option in AutomaticMessageDeletion.values)
              ListTile(
                title: Text(_deletionLabel(l10n, option)),
                trailing: option == current ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(ctx, option),
              ),
          ],
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    await vm.setAutomaticMessageDeletion(chosen);
  }

  Future<void> _pickDefaultEncryption(
    BuildContext context,
    Track current,
    SettingsViewModel vm,
  ) async {
    final l10n = context.l10n;
    final tg = context.tg;
    final chosen = await showModalBottomSheet<Track>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final track in Track.values)
              ListTile(
                leading: Icon(
                  track.icon,
                  color: track == Track.none ? tg.danger : tg.accent,
                ),
                title: Text(track.localizedShortLabel(l10n)),
                subtitle: Text(track.localizedDescription(l10n)),
                trailing: track == current ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(ctx, track),
              ),
          ],
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    await vm.setGlobalEncryption(chosen);
  }

  Future<void> _pickAccent(
    BuildContext context,
    AccentPreference current,
  ) async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final dynamicSwatch = Theme.of(context).colorScheme.primary;
    final chosen = await showModalBottomSheet<AccentPreference>(
      context: context,
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: _DynamicAccentDot(color: dynamicSwatch),
                  title: Text(l10n.themeColorDynamic),
                  subtitle: Text(l10n.themeColorSummary),
                  trailing: current.useDynamic ? const Icon(Icons.check) : null,
                  onTap: () =>
                      Navigator.pop(ctx, const AccentPreference.dynamic()),
                ),
                const SizedBox(height: 8),
                Text(
                  l10n.themeColorFixed,
                  style: Theme.of(ctx).textTheme.labelLarge,
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    for (final option in AccentColor.values)
                      InkWell(
                        onTap: () =>
                            Navigator.pop(ctx, AccentPreference.fixed(option)),
                        customBorder: const CircleBorder(),
                        child: Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: option.swatch,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color:
                                  !current.useDynamic && current.fixed == option
                                  ? Theme.of(ctx).colorScheme.onSurface
                                  : Colors.black26,
                              width:
                                  !current.useDynamic && current.fixed == option
                                  ? 3
                                  : 1,
                            ),
                          ),
                          child: !current.useDynamic && current.fixed == option
                              ? const Icon(
                                  Icons.check,
                                  color: Colors.white,
                                  size: 22,
                                )
                              : null,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
    if (chosen == null || !mounted) return;
    await ref.read(accentPreferenceProvider.notifier).setPreference(chosen);
    if (!chosen.useDynamic) return;
    // Android S+ / desktop accents — null means we seed-fallback.
    final palette = await DynamicColorPlugin.getCorePalette();
    final accentColor = await DynamicColorPlugin.getAccentColor();
    if (!mounted) return;
    if (palette == null && accentColor == null) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.themeColorDynamicUnavailable)),
      );
    }
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
}

class _AccentDot extends StatelessWidget {
  const _AccentDot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.black26),
      ),
    );
  }
}

/// Material You mark: primary swatch with a small “auto” badge.
class _DynamicAccentDot extends StatelessWidget {
  const _DynamicAccentDot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 28,
      height: 28,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  color,
                  Color.lerp(color, Colors.white, 0.35)!,
                  Color.lerp(color, Colors.black, 0.25)!,
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.black26),
            ),
          ),
          const Icon(Icons.auto_awesome, size: 12, color: Colors.white),
        ],
      ),
    );
  }
}
