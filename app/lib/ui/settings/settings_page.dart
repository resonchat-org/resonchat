// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:resonchat/crypto/dual/blind_trust_prefs.dart';
import 'package:resonchat/crypto/dual/track.dart';
import 'package:resonchat/l10n/l10n.dart';
import 'package:resonchat/l10n/locale_controller.dart';
import 'package:resonchat/logging/dev_log.dart';
import 'package:resonchat/logging/dev_log_prefs.dart';
import 'package:resonchat/net/app_network.dart';
import 'package:resonchat/platform/android_keepalive.dart';
import 'package:resonchat/security/app_lock.dart';
import 'package:resonchat/state/providers.dart';
import 'package:resonchat/translate/translation_engine.dart';
import 'package:resonchat/translate/translation_prefs.dart';
import 'package:resonchat/ui/accent_theme.dart';
import 'package:resonchat/ui/archive/archive_page.dart';
import 'package:resonchat/ui/settings/app_lock_pin_sheet.dart';
import 'package:resonchat/ui/settings/auto_reply_page.dart';
import 'package:resonchat/ui/settings/settings_viewmodel.dart';
import 'package:resonchat/ui/settings/socks5_proxy_sheet.dart';
import 'package:resonchat/ui/settings/translation_settings_sheet.dart';
import 'package:resonchat/ui/theme.dart';
import 'package:resonchat/untracker/prefs.dart';
import 'package:resonchat/xmpp/auto_reply.dart';
import 'package:resonchat/xmpp/history_sync.dart';
import 'package:resonchat/xmpp/media/file_preview.dart';
import 'package:resonchat/xmpp/message_expiry.dart';
import 'package:resonchat/xmpp/roster/channel_discovery.dart';

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
  bool _omemoBlindTrust = true;
  int _previewMaxBytes = kDefaultPreviewMaxFileSize;
  bool _devLogEnabled = false;
  AutoReplyConfig _autoReply = AutoReplyConfig.empty;
  HistorySyncSetting _historySync = HistorySyncSetting.fallback;

  @override
  void initState() {
    super.initState();
    unawaited(_reloadTranslationPrefs());
    unawaited(_reloadChannelMethod());
    unawaited(_reloadRemoveTracking());
    unawaited(_reloadOmemoBlindTrust());
    unawaited(_reloadPreviewMax());
    unawaited(_reloadDevLog());
    unawaited(_reloadAutoReply());
    unawaited(_reloadHistorySync());
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

  Future<void> _reloadOmemoBlindTrust() async {
    final enabled = await loadOmemoBlindTrust();
    if (!mounted) return;
    setState(() => _omemoBlindTrust = enabled);
  }

  Future<void> _setOmemoBlindTrust(bool enabled) async {
    await saveOmemoBlindTrust(enabled);
    if (!mounted) return;
    setState(() => _omemoBlindTrust = enabled);
  }

  Future<void> _reloadPreviewMax() async {
    final bytes = await loadPreviewMaxFileSize();
    if (!mounted) return;
    setState(() => _previewMaxBytes = bytes);
  }

  Future<void> _reloadAutoReply() async {
    final config = await loadAutoReply();
    if (!mounted) return;
    setState(() => _autoReply = config);
  }

  Future<void> _reloadHistorySync() async {
    final setting = await loadHistorySyncSetting(
      ref.read(prefsDatabaseProvider),
    );
    if (!mounted) return;
    setState(() => _historySync = setting);
  }

  Future<void> _reloadDevLog() async {
    final enabled = await loadDevLogEnabled();
    if (!mounted) return;
    setState(() => _devLogEnabled = enabled);
  }

  /// Turning the mode on raises the log level and opens the file; turning it
  /// off closes it. Logging starts here rather than at the next launch so that
  /// reproducing something means "flip it, do the thing".
  Future<void> _setDevLog(bool enabled) async {
    await devLog.setEnabled(enabled);
    if (!mounted) return;
    setState(() => _devLogEnabled = enabled);
  }

  /// Conversations-style: explain first, then open the system allow-list dialog.
  Future<void> _requestBatteryOptimizations(BuildContext context) async {
    final l10n = context.l10n;
    final already = await AndroidKeepAlive.isIgnoringBatteryOptimizations();
    if (!context.mounted) return;
    if (already) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.ignoreBatteryOptimizationsAlready)),
      );
      return;
    }
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.ignoreBatteryOptimizationsDialogTitle),
        content: Text(l10n.ignoreBatteryOptimizationsDialogBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.ignoreBatteryOptimizationsDialogNext),
          ),
        ],
      ),
    );
    if (go != true || !context.mounted) return;
    await AndroidKeepAlive.requestIgnoreBatteryOptimizations();
  }

  /// Copies the newest log into Downloads. This is the whole point of the
  /// mode on a phone: the file has to be reachable by a file manager or a
  /// share sheet without a cable.
  Future<void> _exportDevLog() async {
    final l10n = context.l10n;
    String? path;
    Object? failure;
    try {
      path = await devLog.exportToDownloads();
    } catch (e) {
      failure = e;
    }
    if (!mounted) return;
    final message = failure != null
        ? l10n.devLogExportFailed('$failure')
        : path == null
        ? l10n.devLogExportEmpty
        : l10n.devLogExported(path);
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
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
    final xmpp = ref.watch(xmppServiceOrNullProvider);
    final deliveryReceipts =
        settings.deliveryReceipts ?? xmpp?.sendDeliveryReceipts ?? true;
    final readReceipts =
        settings.readReceipts ?? xmpp?.sendReadReceipts ?? true;
    final chatStates =
        settings.chatStates ?? xmpp?.sendTypingNotifications ?? true;
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
          SwitchListTile(
            secondary: const Icon(Icons.shield_outlined),
            title: Text(l10n.omemoBlindTrust),
            subtitle: Text(l10n.omemoBlindTrustSummary),
            value: _omemoBlindTrust,
            onChanged: (v) => unawaited(_setOmemoBlindTrust(v)),
          ),

          _header(tg, l10n.messageSettings),
          SwitchListTile(
            secondary: const Icon(Icons.done),
            title: Text(l10n.deliveryReceipts),
            subtitle: Text(l10n.deliveryReceiptsSummary),
            value: deliveryReceipts,
            onChanged: (v) => unawaited(vm.setDeliveryReceipts(v)),
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
            leading: const Icon(Icons.history),
            title: Text(l10n.historySyncTitle),
            subtitle: Text(
              '${_historySyncLabel(l10n, _historySync)}\n'
              '${l10n.historySyncSummary}',
            ),
            onTap: () => unawaited(_pickHistorySync(context)),
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
          ListTile(
            leading: const Icon(Icons.download_outlined),
            title: Text(l10n.previewMaxFileSize),
            subtitle: Text(
              '${_previewLimitLabel(l10n, _previewMaxBytes)}\n'
              '${l10n.previewMaxFileSizeSummary}',
            ),
            onTap: () => unawaited(_pickPreviewMax(context)),
          ),
          ListTile(
            leading: const Icon(Icons.quickreply_outlined),
            title: Text(l10n.autoReply),
            subtitle: Text(
              _autoReply.enabled
                  ? l10n.autoReplyRuleCount(_autoReply.rules.length)
                  : l10n.autoReplyOff,
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              await Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const AutoReplyPage()),
              );
              await _reloadAutoReply();
            },
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
          if (AndroidKeepAlive.isSupported)
            ListTile(
              leading: const Icon(Icons.battery_saver_outlined),
              title: Text(l10n.ignoreBatteryOptimizations),
              subtitle: Text(l10n.ignoreBatteryOptimizationsSummary),
              onTap: () => unawaited(_requestBatteryOptimizations(context)),
            ),
          Builder(
            builder: (context) {
              final prefs = _translationPrefs;
              final subtitle = switch (prefs?.engine) {
                null => l10n.translationSummary,
                TranslationEngineId.offlineTranslator =>
                  l10n.translationOfflineTranslator,
                TranslationEngineId.deepL =>
                  prefs!.apiKey.trim().isEmpty
                      ? l10n.translationSummary
                      : l10n.translationDeepL,
                TranslationEngineId.libreTranslate =>
                  prefs!.baseUrl.trim().isEmpty
                      ? l10n.translationSummary
                      : prefs.baseUrl.trim(),
              };
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

          // Developer last: it is for diagnosing the app, not for using it.
          if (devLog.supported) ...[
            _header(tg, l10n.developer),
            SwitchListTile(
              secondary: const Icon(Icons.bug_report_outlined),
              title: Text(l10n.devLogMode),
              subtitle: Text(l10n.devLogModeSummary),
              value: _devLogEnabled,
              onChanged: (v) => unawaited(_setDevLog(v)),
            ),
            if (_devLogEnabled)
              ListTile(
                leading: const Icon(Icons.save_alt),
                title: Text(l10n.devLogExport),
                subtitle: Text(l10n.devLogExportSummary),
                onTap: () => unawaited(_exportDevLog()),
              ),
          ],

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
    AutomaticMessageDeletion.untilClosed =>
      l10n.automaticMessageDeletionUntilClosed,
    AutomaticMessageDeletion.oneDay => l10n.automaticMessageDeletionOneDay,
    AutomaticMessageDeletion.oneWeek => l10n.automaticMessageDeletionOneWeek,
    AutomaticMessageDeletion.oneMonth => l10n.automaticMessageDeletionOneMonth,
    AutomaticMessageDeletion.threeMonths =>
      l10n.automaticMessageDeletionThreeMonths,
    AutomaticMessageDeletion.sixMonths =>
      l10n.automaticMessageDeletionSixMonths,
    AutomaticMessageDeletion.oneYear => l10n.automaticMessageDeletionOneYear,
    AutomaticMessageDeletion.never => l10n.automaticMessageDeletionNever,
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

  String _historySyncLabel(AppLocalizations l10n, HistorySyncSetting setting) {
    return switch (setting.mode) {
      HistorySyncMode.off => l10n.historySyncOff,
      HistorySyncMode.count => l10n.historySyncMessages(setting.count),
      HistorySyncMode.days => _historySyncDaysLabel(l10n, setting.days),
    };
  }

  String _historySyncDaysLabel(AppLocalizations l10n, int days) {
    return switch (days) {
      1 => l10n.historySyncOneDay,
      2 => l10n.historySyncTwoDays,
      7 => l10n.historySyncOneWeek,
      30 => l10n.historySyncOneMonth,
      90 => l10n.historySyncOneQuarter,
      180 => l10n.historySyncSixMonths,
      365 => l10n.historySyncOneYear,
      _ => l10n.historySyncOneWeek,
    };
  }

  Future<void> _pickHistorySync(BuildContext context) async {
    final l10n = context.l10n;
    var draft = _historySync;
    final chosen = await showModalBottomSheet<HistorySyncSetting>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheet) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 8, 0, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Text(
                        l10n.historySyncTitle,
                        style: Theme.of(ctx).textTheme.titleMedium,
                      ),
                    ),
                    ListTile(
                      title: Text(l10n.historySyncOff),
                      trailing: draft.mode == HistorySyncMode.off
                          ? const Icon(Icons.check)
                          : null,
                      onTap: () => setSheet(
                        () => draft = draft.copyWith(mode: HistorySyncMode.off),
                      ),
                    ),
                    ListTile(
                      title: Text(l10n.historySyncByCount),
                      trailing: draft.mode == HistorySyncMode.count
                          ? const Icon(Icons.check)
                          : null,
                      onTap: () => setSheet(
                        () =>
                            draft = draft.copyWith(mode: HistorySyncMode.count),
                      ),
                    ),
                    if (draft.mode == HistorySyncMode.count)
                      _discreteOptionSlider(
                        context: ctx,
                        options: HistorySyncSetting.countOptions,
                        value: draft.count,
                        labelOf: l10n.historySyncMessages,
                        onChanged: (count) => setSheet(
                          () => draft = draft.copyWith(
                            mode: HistorySyncMode.count,
                            count: count,
                          ),
                        ),
                      ),
                    ListTile(
                      title: Text(l10n.historySyncByDays),
                      trailing: draft.mode == HistorySyncMode.days
                          ? const Icon(Icons.check)
                          : null,
                      onTap: () => setSheet(
                        () =>
                            draft = draft.copyWith(mode: HistorySyncMode.days),
                      ),
                    ),
                    if (draft.mode == HistorySyncMode.days)
                      _discreteOptionSlider(
                        context: ctx,
                        options: HistorySyncSetting.dayOptions,
                        value: draft.days,
                        labelOf: (days) => _historySyncDaysLabel(l10n, days),
                        onChanged: (days) => setSheet(
                          () => draft = draft.copyWith(
                            mode: HistorySyncMode.days,
                            days: days,
                          ),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                      child: FilledButton(
                        onPressed: () => Navigator.pop(ctx, draft),
                        child: Text(l10n.save),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
    if (chosen == null || !mounted) return;
    await saveHistorySyncSetting(ref.read(prefsDatabaseProvider), chosen);
    setState(() => _historySync = chosen);
  }

  /// A track with tick marks for each discrete option and a draggable thumb.
  Widget _discreteOptionSlider<T>({
    required BuildContext context,
    required List<T> options,
    required T value,
    required String Function(T) labelOf,
    required ValueChanged<T> onChanged,
  }) {
    final index = options.indexOf(value).clamp(0, options.length - 1);
    final scheme = Theme.of(context).colorScheme;
    final tickStyle = Theme.of(context).textTheme.labelSmall
        ?.copyWith(color: scheme.onSurfaceVariant, fontSize: 10);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              labelOf(options[index]),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          Slider(
            value: index.toDouble(),
            min: 0,
            max: (options.length - 1).toDouble(),
            divisions: options.length - 1,
            label: labelOf(options[index]),
            onChanged: (raw) {
              final next = raw.round().clamp(0, options.length - 1);
              onChanged(options[next]);
            },
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                for (final option in options)
                  Expanded(
                    child: Text(
                      labelOf(option),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: tickStyle,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickAutomaticDeletion(
    BuildContext context,
    AutomaticMessageDeletion current,
    SettingsViewModel vm,
  ) async {
    final l10n = context.l10n;
    var draft = current;
    final chosen = await showModalBottomSheet<AutomaticMessageDeletion>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheet) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 8, 0, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Text(
                        l10n.automaticMessageDeletion,
                        style: Theme.of(ctx).textTheme.titleMedium,
                      ),
                    ),
                    _discreteOptionSlider(
                      context: ctx,
                      options: AutomaticMessageDeletion.values,
                      value: draft,
                      labelOf: (option) => _deletionLabel(l10n, option),
                      onChanged: (option) => setSheet(() => draft = option),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                      child: FilledButton(
                        onPressed: () => Navigator.pop(ctx, draft),
                        child: Text(l10n.save),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
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

  String _previewLimitLabel(AppLocalizations l10n, int bytes) {
    return switch (bytes) {
      0 => l10n.noAutomaticPreview,
      262144 => '256 KiB',
      524288 => '512 KiB',
      1048576 => '1 MiB',
      5242880 => '5 MiB',
      10485760 => '10 MiB',
      26214400 => '25 MiB',
      _ => l10n.noAutomaticPreview,
    };
  }

  Future<void> _pickPreviewMax(BuildContext context) async {
    final l10n = context.l10n;
    var draft = _previewMaxBytes;
    final chosen = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheet) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 8, 0, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Text(
                        l10n.previewMaxFileSize,
                        style: Theme.of(ctx).textTheme.titleMedium,
                      ),
                    ),
                    _discreteOptionSlider(
                      context: ctx,
                      options: previewMaxFileSizeChoices,
                      value: draft,
                      labelOf: (bytes) => _previewLimitLabel(l10n, bytes),
                      onChanged: (bytes) => setSheet(() => draft = bytes),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                      child: FilledButton(
                        onPressed: () => Navigator.pop(ctx, draft),
                        child: Text(l10n.save),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
    if (chosen == null || !mounted) return;
    await savePreviewMaxFileSize(chosen);
    setState(() => _previewMaxBytes = chosen);
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
