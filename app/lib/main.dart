// Copyright (C) 2026 resonchat contributors.
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
import 'l10n/l10n.dart';
import 'net/app_network.dart';
import 'platform/app_notifications.dart';
import 'state/app_wiring.dart';
import 'security/app_lock.dart';
import 'store/prefs_database.dart';
import 'ui/accent_theme.dart';
import 'ui/disguise/disguise_2048_page.dart';
import 'ui/home/home_shell.dart';
import 'ui/column_mode_sync.dart';
import 'ui/login/login_page.dart';
import 'ui/login/register_page.dart';
import 'ui/chat/chat_page.dart';
import 'ui/accounts/manage_accounts_page.dart';
import 'ui/security/security_page.dart';
import 'ui/profile/profile_page.dart';
import 'ui/settings/settings_page.dart';

/// Root navigator — used to remap `/chat` ↔ column pane across resizes.
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (kDebugMode) {
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen((record) {
      debugPrint(
        '[${record.level.name}] ${record.loggerName}: ${record.message}',
      );
    });
  }

  // Shared prefs DB first (SOCKS / locale), before any account session.
  final prefs = await openAppPrefs();
  await AppLock.instance.load(prefs);

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

  runApp(
    ProviderScope(
      child: App(hasAccounts: hub.hasAccounts, initialChatKey: launchChatKey),
    ),
  );
}

void _openChatFromNotification(String chatKey) {
  final nav = appNavigatorKey.currentState;
  if (nav == null) return;
  final ref = ChatRef.tryParse(chatKey);
  if (ref == null) return;
  nav.pushNamed('/chat', arguments: ref);
}

class App extends ConsumerStatefulWidget {
  const App({super.key, required this.hasAccounts, this.initialChatKey});

  final bool hasAccounts;

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
    if (key != null && widget.hasAccounts && !AppLock.instance.needsDisguise) {
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
          builder: (context, child) {
            return AppWiring(
              child: ListenableBuilder(
                listenable: AppLock.instance,
                builder: (context, _) {
                  final body = ColumnModeSync(
                    navigatorKey: appNavigatorKey,
                    child: child ?? const SizedBox.shrink(),
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
          initialRoute: widget.hasAccounts ? '/chats' : '/login',
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
