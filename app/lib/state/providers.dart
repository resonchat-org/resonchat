// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:moxxmpp/moxxmpp.dart' show JID;

import '../omemo/dual_track_manager.dart';
import '../omemo/protocol.dart';
import '../store/database.dart';
import '../store/omemo_device_store.dart';
import '../xmpp/b_track_manager.dart';
import '../xmpp/capabilities.dart';
import '../xmpp/connection.dart';

/// Overridden in `main()` with the opened database.
final databaseProvider = Provider<AppDatabase>(
  (ref) => throw UnimplementedError('databaseProvider not overridden'),
);

final capabilityServiceProvider = Provider<CapabilityService>((ref) {
  final service = CapabilityService(
    tracks: () => ref.read(dualTrackManagerProvider)!,
    ourDeviceId: () async => ref.read(xmppServiceProvider).omemo?.getDeviceId(),
  );
  // Let the connection consult this when deciding whether to encrypt.
  // Done in a side-effecting provider rather than inside the factory, so
  // the factory itself stays pure (Riverpod may call it more than once).
  return service;
});

/// Wires the capability service into the connection exactly once.
final Provider<void> _capabilityWiringProvider = Provider<void>((ref) {
  final service = ref.watch(capabilityServiceProvider);
  final xmpp = ref.watch(xmppServiceProvider);
  xmpp.attachCapabilities(service);
  final sub = xmpp.capabilityChanges.listen((jid) {
    ref.read(capabilityServiceProvider).invalidate(jid);
  });
  ref.onDispose(sub.cancel);
});

/// The dual-track managers, available once the connection is up.
final Provider<DualTrackManager?> dualTrackManagerProvider = Provider<DualTrackManager?>((ref) {
  ref.watch(_capabilityWiringProvider);
  final xmpp = ref.watch(xmppServiceProvider);
  final moxxOmemo = xmpp.moxxOmemo;
  final pubsub = xmpp.pubsub;
  if (moxxOmemo == null || pubsub == null) return null;
  final tracks = DualTrackManager(
    aTrack: moxxOmemo,
    pubsubOf: () => pubsub,
  );
  // Let the service publish our A-track bundle in both wire dialects.
  xmpp.tracks = tracks;
  return tracks;
});

final Provider<XmppService> xmppServiceProvider = Provider<XmppService>((
  ref,
) {
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
    bTrack: ref.read(bTrackManagerProvider),
  );
});

/// Owns the local PQ device, its bundle publication and PQ messaging.
///
/// Resolved lazily through [ref] inside the callbacks, so this provider
/// can be created before the connection exists without a dependency cycle.
final Provider<BTrackManager> bTrackManagerProvider = Provider<BTrackManager>(
  (ref) => BTrackManager(
    tracks: () => ref.read(dualTrackManagerProvider)!,
    pubsubOf: () => ref.read(xmppServiceProvider).pubsub,
  ),
);

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

/// Live capability snapshot for a chat, or null while resolving.
///
/// The encryption info page shows this so the user can see exactly which
/// devices are counted as recipients.
final chatCapabilitiesProvider =
    FutureProvider.family<ChatCapabilities?, String>((ref, chatJid) async {
      ref.watch(connectionStateProvider);
      final xmpp = ref.read(xmppServiceProvider);
      if (xmpp.omemo == null) return null;
      final caps =
          await ref.read(capabilityServiceProvider).forChat(JID.fromString(chatJid));
      return caps.reliable ? caps : null;
    });

/// Encryption mode for a chat, or [EncMode.none] while resolving.
///
/// UI-facing convenience over [encModeProvider]; never blocks on the
/// network, so a chat row renders immediately with an honest "not yet
/// encrypted" state instead of a spinner.
final chatEncModeProvider = Provider.family<EncMode, String>((ref, chatJid) {
  return ref.watch(encModeProvider(chatJid)).maybeWhen(
        data: (mode) => mode,
        orElse: () => EncMode.none,
      );
});

/// Per-chat outbound encryption mode, resolved from live capability data
/// (M4). Recomputes whenever the connection or cache changes; falls back
/// to [EncMode.none] while resolving or when data is unreliable, so the
/// UI never claims a protection level we cannot guarantee.
final encModeProvider =
    FutureProvider.family<EncMode, String>((ref, chatJid) async {
      // Watching the connection forces a re-resolve after reconnect.
      ref.watch(connectionStateProvider);
      final xmpp = ref.read(xmppServiceProvider);
      if (xmpp.omemo == null) return EncMode.none;
      final caps = await ref
          .read(capabilityServiceProvider)
          .forChat(JID.fromString(chatJid));
      return caps.reliable ? caps.mode : EncMode.none;
    });
