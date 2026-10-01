// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'state/providers.dart';
import 'store/database.dart';
import 'ui/chats_page.dart';
import 'ui/login_page.dart';
import 'ui/chat_page.dart';
import 'ui/security_page.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final db = await openAppDatabase();
  runApp(ProviderScope(overrides: [databaseProvider.overrideWithValue(db)], child: const App()));
}

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'resonchat',
      debugShowCheckedModeBanner: false,
      theme: AppThemeTokens.light(),
      darkTheme: AppThemeTokens.dark(),
      initialRoute: '/login',
      routes: {
        '/login': (_) => const LoginPage(),
        '/chats': (_) => const ChatsPage(),
        '/chat': (ctx) => ChatPage(
            chatJid: ModalRoute.of(ctx)!.settings.arguments! as String),
        '/encryption': (ctx) => SecurityPage(
            chatJid: ModalRoute.of(ctx)!.settings.arguments! as String),
        '/settings': (_) => const SettingsPage(),
      },
    );
  }
}