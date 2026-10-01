// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../omemo/protocol.dart';
import '../store/database.dart';
import '../xmpp/connection.dart';

/// Overridden in `main()` with the opened database.
final databaseProvider = Provider<AppDatabase>(
  (ref) => throw UnimplementedError('databaseProvider not overridden'),
);

final xmppServiceProvider = Provider<XmppService>((ref) => XmppService());

final connectionStateProvider = StateProvider<XmppConnectionState>(
  (ref) => XmppConnectionState.disconnected,
);

/// Live message list for one chat.
final messagesProvider =
    StreamProvider.family<List<Message>, String>((ref, chatJid) {
  return ref.watch(databaseProvider).watchMessages(chatJid);
});

/// Live chat list.
final chatsProvider = StreamProvider<List<Chat>>(
  (ref) => ref.watch(databaseProvider).watchChats(),
);

/// Per-chat outbound encryption mode (M4 drives this from capability
/// state; M1/M2 default to plaintext until the user enables OMEMO).
final encModeProvider =
    StateProvider.family<EncMode, String>((ref, chatJid) => EncMode.none);
