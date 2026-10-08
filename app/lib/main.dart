// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

import 'account/account_hub.dart';
import 'account/chat_ref.dart';
import 'l10n/l10n.dart';
import 'net/app_network.dart';
import 'state/app_wiring.dart';
import 'ui/chats_page.dart';
import 'ui/login_page.dart';
import 'ui/chat_page.dart';
import 'ui/manage_accounts_page.dart';
import 'ui/security_page.dart';
import 'ui/profile_page.dart';
import 'ui/settings_page.dart';
import 'ui/theme.dart';

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

  final hub = AccountHub();
  installAccountHub(hub);
  // Open DBs first, apply SOCKS, then connect — never race proxy load.
  await hub.openSessions();

  final primaryDb = hub.primaryDbOrNull;
  if (primaryDb != null) {
    await appNetwork.loadFrom(() async {
      return Socks5ProxyConfig(
        enabled: await primaryDb.socks5ProxyEnabled(),
        host: await primaryDb.socks5ProxyHost(),
        port: await primaryDb.socks5ProxyPort(),
      );
    });
  }

  await hub.connectAll();

  runApp(
    ProviderScope(
      child: App(hasAccounts: hub.hasAccounts),
    ),
  );
}

class App extends ConsumerWidget {
  const App({super.key, required this.hasAccounts});

  final bool hasAccounts;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final localeOverride = ref.watch(localeOverrideProvider);
    return MaterialApp(
      onGenerateTitle: (context) => context.l10n.appName,
      debugShowCheckedModeBanner: false,
      theme: AppThemeTokens.light(),
      darkTheme: AppThemeTokens.dark(),
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
      builder: (context, child) => AppWiring(
        child: child ?? const SizedBox.shrink(),
      ),
      initialRoute: hasAccounts ? '/chats' : '/login',
      onGenerateRoute: (settings) {
        switch (settings.name) {
          case '/login':
            final addAccount = settings.arguments == true;
            return MaterialPageRoute<void>(
              settings: settings,
              builder: (_) => LoginPage(addAccountMode: addAccount),
            );
          case '/chats':
            return MaterialPageRoute<void>(
              settings: settings,
              builder: (_) => const ChatsPage(),
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
              builder: (_) => ProfilePage(
                chatJid: settings.arguments! as String,
              ),
            );
          case '/encryption':
            return MaterialPageRoute<void>(
              settings: settings,
              builder: (_) => SecurityPage(
                chatJid: settings.arguments! as String,
              ),
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
  }
}
