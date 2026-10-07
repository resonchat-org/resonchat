// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

import 'l10n/l10n.dart';
import 'state/app_wiring.dart';
import 'state/providers.dart';
import 'store/database.dart';
import 'ui/chats_page.dart';
import 'ui/login_page.dart';
import 'ui/chat_page.dart';
import 'ui/security_page.dart';
import 'ui/profile_page.dart';
import 'ui/settings_page.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Route package:logging output to logcat/stdout so connection problems
  // are diagnosable on a device (debug builds only).
  if (kDebugMode) {
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen((record) {
      debugPrint(
        '[${record.level.name}] ${record.loggerName}: ${record.message}',
      );
    });
  }

  final db = await openAppDatabase();
  runApp(
    ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: const App(),
    ),
  );
}

class App extends ConsumerWidget {
  const App({super.key});

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
      // Present for the whole app so connection bookkeeping (capabilities,
      // delivery receipts) follows the connection rather than whichever
      // page happens to be on screen.
      builder: (context, child) => AppWiring(
        child: child ?? const SizedBox.shrink(),
      ),
      initialRoute: '/login',
      routes: {
        '/login': (_) => const LoginPage(),
        '/chats': (_) => const ChatsPage(),
        '/chat': (ctx) => ChatPage(
            chatJid: ModalRoute.of(ctx)!.settings.arguments! as String),
        '/profile': (ctx) => ProfilePage(
            chatJid: ModalRoute.of(ctx)!.settings.arguments! as String),
        '/encryption': (ctx) => SecurityPage(
            chatJid: ModalRoute.of(ctx)!.settings.arguments! as String),
        '/settings': (_) => const SettingsPage(),
      },
    );
  }
}
