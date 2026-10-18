// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

import 'account/account_hub.dart';
import 'account/chat_ref.dart';
import 'crypto/libsignal_bootstrap.dart';
import 'l10n/l10n.dart';
import 'l10n/locale_controller.dart';
import 'logging/dev_log.dart';
import 'logging/dev_log_prefs.dart';
import 'net/app_network.dart';
import 'net/socks5_config.dart';
import 'platform/app_notifications.dart';
import 'state/app_wiring.dart';
import 'security/app_lock.dart';
import 'store/prefs_database.dart';
import 'ui/accent_theme.dart';
import 'ui/disguise/disguise_2048_page.dart';
import 'ui/home/home_shell.dart';
import 'ui/home/landscape_rail.dart';
import 'ui/home/shell_chrome.dart';
import 'ui/column_mode_sync.dart';
import 'ui/login/login_page.dart';
import 'ui/login/register_page.dart';
import 'ui/chat/chat_page.dart';
import 'ui/accounts/manage_accounts_page.dart';
import 'ui/security/security_page.dart';
import 'ui/profile/profile_page.dart';
import 'ui/room/room_profile_page.dart';
import 'ui/settings/settings_page.dart';

/// Root navigator — used to remap `/chat` ↔ column pane across resizes.
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

/// True while `/chats` is still in the root stack (landscape rail).
final shellChrome = ShellChrome();

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  if (kDebugMode) {
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen((record) {
      debugPrint(
        '[${record.level.name}] ${record.loggerName}: ${record.message}',
      );
    });
  }

  // `runApp` happens exactly once, from [StartupGate]: booting can fail, and a
  // failure needs somewhere to land that is not an unhandled exception.
  runApp(const StartupGate());
}

/// What a successful [bootApp] hands to the UI.
class StartupResult {
  const StartupResult({
    required this.hasAccounts,
    required this.hasEnabledAccounts,
    this.launchChatKey,
  });

  final bool hasAccounts;

  /// False when every stored account is disabled — open manage-accounts,
  /// not the chat shell (no primary session).
  final bool hasEnabledAccounts;

  final String? launchChatKey;
}

/// Everything that has to happen before the first frame.
///
/// Separate from [main] so [StartupGate] can report a failure and try again.
/// These steps open the on-disk databases, and opening one refuses to proceed
/// unencrypted rather than quietly falling back to plaintext (see
/// `openAppDatabase`). Before this split, a refusal — or an unreadable keystore,
/// or a build without SQLCipher — surfaced as an unhandled exception *before*
/// `runApp`: no window, no message, the reason only in logcat.
///
/// Public, and not inlined into [StartupGate], because it touches the platform
/// (path provider, keystore, notifications) and so cannot be run under
/// `flutter test`. Tests drive the gate with their own function instead.
Future<StartupResult> bootApp() async {
  // Native libsignal (PQXDH + SPQR) before any B-track crypto.
  await ensureLibSignal();

  // Shared prefs DB first (SOCKS / locale), before any account session.
  final prefs = await openAppPrefs();
  await AppLock.instance.load(prefs);

  // Developer log mode, before the first session: the connect sequence and the
  // capability lookups are the part this file exists to capture.
  if (await loadDevLogEnabled(prefs)) {
    await devLog.start();
  }

  final hub = AccountHub();
  installAccountHub(hub);
  // Open account DBs, apply SOCKS from prefs, then connect — never race proxy.
  await hub.openSessions();

  await appNetwork.loadFrom(() async {
    return Socks5ProxyConfig(
      enabled: await prefs.socks5ProxyEnabled(),
      host: await prefs.socks5ProxyHost(),
      port: await prefs.socks5ProxyPort(),
    );
  });

  AppNotifications.instance.onOpenChat = _openChatFromNotification;
  await AppNotifications.instance.ensureReady();
  final launchChatKey = await AppNotifications.instance.launchChatKey();

  // Skip opening a chat under the disguise gate.
  if (!AppLock.instance.needsDisguise) {
    await hub.connectAll();
  } else {
    // Still connect in the background; UI stays on 2048 until unlock.
    unawaited(hub.connectAll());
  }

  return StartupResult(
    hasAccounts: hub.hasAccounts,
    hasEnabledAccounts: hub.hasEnabledAccounts,
    launchChatKey: launchChatKey,
  );
}

/// Boots the app, or explains why it could not.
///
/// UI rule (same as [App] after mount): while [AppLock.needsDisguise], only
/// 2048 is shown — progress / "could not start" wait until unlock.
class StartupGate extends StatefulWidget {
  const StartupGate({super.key, this.boot = bootApp});

  /// Defaults to the real sequence; tests substitute one that fails on purpose.
  final Future<StartupResult> Function() boot;

  @override
  State<StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends State<StartupGate> {
  StartupResult? _booted;
  Object? _error;
  bool _running = true;

  @override
  void initState() {
    super.initState();
    // [bootApp] loads AppLock early; rebuild so 2048 can cover mid-boot.
    AppLock.instance.addListener(_onLockChanged);
    unawaited(_run());
  }

  @override
  void dispose() {
    AppLock.instance.removeListener(_onLockChanged);
    super.dispose();
  }

  void _onLockChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _run() async {
    setState(() {
      _running = true;
      _error = null;
      _booted = null;
    });
    try {
      final booted = await widget.boot();
      if (!mounted) return;
      setState(() {
        _booted = booted;
        _running = false;
      });
    } catch (error, stack) {
      Logger('main').severe('startup failed', error, stack);
      if (!mounted) return;
      setState(() {
        _error = error;
        _running = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Same condition [App] uses — one gate everywhere.
    if (AppLock.instance.needsDisguise) {
      return _StartupShell(
        child: Disguise2048Page(onUnlocked: () => setState(() {})),
      );
    }

    final booted = _booted;
    if (booted != null) {
      return ProviderScope(
        child: App(
          hasAccounts: booted.hasAccounts,
          hasEnabledAccounts: booted.hasEnabledAccounts,
          initialChatKey: booted.launchChatKey,
        ),
      );
    }

    // Still booting: spinner only (no "could not start" title — that page is
    // for failures, and would flash before 2048 when disguise turns on).
    if (_running) {
      return const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          backgroundColor: Color(0xFFFAF8EF),
          body: Center(child: CircularProgressIndicator()),
        ),
      );
    }

    return _StartupShell(
      child: _StartupStatusBody(error: _error, onRetry: _run),
    );
  }
}

/// Minimal MaterialApp for pre-[App] chrome (2048 or boot status).
class _StartupShell extends StatelessWidget {
  const _StartupShell({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(),
      darkTheme: ThemeData(brightness: Brightness.dark),
      themeMode: ThemeMode.system,
      supportedLocales: supportedAppLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: child,
    );
  }
}

/// Failure body after boot threw (hosted by [_StartupShell]).
class _StartupStatusBody extends StatelessWidget {
  const _StartupStatusBody({required this.error, required this.onRetry});

  final Object? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.lock_outline, size: 40),
                const SizedBox(height: 16),
                Text(
                  l10n.startupFailedTitle,
                  style: theme.textTheme.titleLarge,
                ),
                const SizedBox(height: 16),
                Text(l10n.startupFailedBody),
                const SizedBox(height: 12),
                Text(l10n.startupFailedHint),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: onRetry,
                  child: Text(l10n.startupFailedRetry),
                ),
                if (error != null) ...[
                  const SizedBox(height: 28),
                  Text(
                    l10n.startupFailedDetails,
                    style: theme.textTheme.labelLarge,
                  ),
                  const SizedBox(height: 6),
                  SelectableText('$error', style: theme.textTheme.bodySmall),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

void _openChatFromNotification(String chatKey) {
  final nav = appNavigatorKey.currentState;
  if (nav == null) return;
  final ref = ChatRef.tryParse(chatKey);
  if (ref == null) return;
  nav.pushNamed('/chat', arguments: ref);
}

class App extends ConsumerStatefulWidget {
  const App({
    super.key,
    required this.hasAccounts,
    required this.hasEnabledAccounts,
    this.initialChatKey,
  });

  final bool hasAccounts;
  final bool hasEnabledAccounts;

  /// Chat opened because the process was launched from a shade tap.
  final String? initialChatKey;

  @override
  ConsumerState<App> createState() => _AppState();
}

class _AppState extends ConsumerState<App> {
  @override
  void initState() {
    super.initState();
    final key = widget.initialChatKey;
    if (key != null &&
        widget.hasEnabledAccounts &&
        !AppLock.instance.needsDisguise) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _openChatFromNotification(key);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final localeOverride = ref.watch(localeOverrideProvider);
    final accent = ref.watch(accentPreferenceProvider);
    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) {
        return MaterialApp(
          navigatorKey: appNavigatorKey,
          onGenerateTitle: (context) => context.l10n.appName,
          debugShowCheckedModeBanner: false,
          theme: themeForAccent(
            preference: accent,
            brightness: Brightness.light,
            dynamicScheme: lightDynamic,
          ),
          darkTheme: themeForAccent(
            preference: accent,
            brightness: Brightness.dark,
            dynamicScheme: darkDynamic,
          ),
          locale: localeOverride,
          supportedLocales: supportedAppLocales,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          localeResolutionCallback: (device, supported) {
            if (localeOverride != null) return localeOverride;
            if (device == null) return const Locale('en');
            for (final locale in supported) {
              if (locale.languageCode == device.languageCode) {
                return locale;
              }
            }
            return const Locale('en');
          },
          navigatorObservers: [shellChrome],
          builder: (context, child) {
            return AppWiring(
              child: ListenableBuilder(
                listenable: AppLock.instance,
                builder: (context, _) {
                  final navigator = child ?? const SizedBox.shrink();
                  final body = ColumnModeSync(
                    navigatorKey: appNavigatorKey,
                    child: ValueListenableBuilder<bool>(
                      valueListenable: shellChrome.visible,
                      child: navigator,
                      builder: (context, shellVisible, navigator) {
                        final landscape =
                            MediaQuery.orientationOf(context) ==
                            Orientation.landscape;
                        final page = navigator ?? const SizedBox.shrink();
                        if (!landscape || !shellVisible) return page;
                        return LandscapeFrame(
                          navigatorKey: appNavigatorKey,
                          child: page,
                        );
                      },
                    ),
                  );
                  if (!AppLock.instance.needsDisguise) return body;
                  // Keep navigator mounted under the disguise so unlock
                  // restores the previous route tree.
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      Offstage(child: body),
                      Disguise2048Page(onUnlocked: () {}),
                    ],
                  );
                },
              ),
            );
          },
          initialRoute: !widget.hasAccounts
              ? '/login'
              : (widget.hasEnabledAccounts ? '/chats' : '/accounts'),
          onGenerateRoute: (settings) {
            switch (settings.name) {
              case '/login':
                final addAccount = settings.arguments == true;
                return MaterialPageRoute<void>(
                  settings: settings,
                  builder: (_) => LoginPage(addAccountMode: addAccount),
                );
              case '/register':
                final addAccount = settings.arguments == true;
                return MaterialPageRoute<void>(
                  settings: settings,
                  builder: (_) => RegisterPage(addAccountMode: addAccount),
                );
              case '/chats':
                return MaterialPageRoute<void>(
                  settings: settings,
                  builder: (_) => const HomeShell(),
                );
              case '/chat':
                final arg = settings.arguments;
                final key = arg is ChatRef
                    ? arg.key
                    : (arg is String ? arg : '');
                return MaterialPageRoute<void>(
                  settings: settings,
                  builder: (_) => ChatPage(chatJid: key),
                );
              case '/profile':
                return MaterialPageRoute<void>(
                  settings: settings,
                  builder: (_) =>
                      ProfilePage(chatJid: settings.arguments! as String),
                );
              case '/room-profile':
                return MaterialPageRoute<RoomProfileResult>(
                  settings: settings,
                  builder: (_) =>
                      RoomProfilePage(chatJid: settings.arguments! as String),
                );
              case '/encryption':
                return MaterialPageRoute<void>(
                  settings: settings,
                  builder: (_) =>
                      SecurityPage(chatJid: settings.arguments! as String),
                );
              case '/settings':
                return MaterialPageRoute<void>(
                  settings: settings,
                  builder: (_) => const SettingsPage(),
                );
              case '/accounts':
                return MaterialPageRoute<void>(
                  settings: settings,
                  builder: (_) => const ManageAccountsPage(),
                );
            }
            return null;
          },
        );
      },
    );
  }
}
