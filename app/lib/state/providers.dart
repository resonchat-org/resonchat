// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../omemo/protocol.dart';
import '../store/database.dart';
import '../store/omemo_device_store.dart';
import '../xmpp/connection.dart';

/// Overridden in `main()` with the opened database.
final databaseProvider = Provider<AppDatabase>(
  (ref) => throw UnimplementedError('databaseProvider not overridden'),
);

final xmppServiceProvider = Provider<XmppService>((ref) {
  // Device keys are sealed under a Keystore-held key and the sealed blob
  // lives in the database (M5 groundwork).
  return XmppService(
    deviceStore: OmemoDeviceStore(
      secureStorage: const FlutterSecureStorage(),
      loadSecret: () async {
        final v = await ref.read(databaseProvider).metaValue(_deviceBlobKey);
        return v == null ? null : base64Decode(v);
      },
      saveSecret: (bytes) => ref
          .read(databaseProvider)
          .setMetaValue(_deviceBlobKey, base64Encode(bytes)),
      deleteSecret: () =>
          ref.read(databaseProvider).deleteMetaValue(_deviceBlobKey),
    ),
  );
});

/// Database key holding the sealed OMEMO device blob.
const _deviceBlobKey = 'omemo_device_blob';

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

/// Last message preview for the chat list row.
final lastMessageProvider = StreamProvider.family<String?, String>(
  (ref, chatJid) => ref.watch(databaseProvider).watchLastMessage(chatJid),
);

/// Per-chat outbound encryption mode (M4 drives this from capability
/// state; M1/M2 default to plaintext until the user enables OMEMO).
final encModeProvider =
    StateProvider.family<EncMode, String>((ref, chatJid) => EncMode.none);
