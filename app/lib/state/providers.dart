// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:moxxmpp/moxxmpp.dart' show JID;

import '../omemo/dual_track_manager.dart';
import '../omemo/protocol.dart';
import '../omemo/track.dart';
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
    // Our own PQ device counts as PQ-capable only once its bundle is
    // published; before that the chat must stay on the A track.
    ourPqDevices: () async {
      final b = ref.read(xmppServiceProvider).bTrack;
      final id = b?.device?.id;
      return (b?.ready ?? false) && id != null ? {id} : const <int>{};
    },
  );
  return service;
});

/// The dual-track managers, available once the connection is up.
final Provider<DualTrackManager?> dualTrackManagerProvider = Provider<DualTrackManager?>((ref) {
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
/// One chat row, or null while loading / unknown.
final chatProvider = FutureProvider.family<Chat?, String>((ref, chatJid) {
  return ref
      .watch(databaseProvider)
      .watchChats()
      .first
      .then((all) => all.where((c) => c.jid == chatJid).firstOrNull);
});

final lastMessageProvider = StreamProvider.family<String?, String>(
  (ref, chatJid) => ref.watch(databaseProvider).watchLastMessage(chatJid),
);

/// Live capability snapshot for a chat, or null while resolving.
///
/// The encryption info page shows this so the user can see exactly which
/// devices are counted as recipients.
/// Subscription state of one contact, and whether it is mutual.
///
/// Delivery is not just crypto: servers commonly refuse stanzas that are not
/// inside a mutual subscription, so the UI has to be able to say so instead
/// of leaving the user wondering why nothing arrives.
final contactStateProvider = FutureProvider.family<ContactState, String>((
  ref,
  chatJid,
) async {
  ref.watch(connectionStateProvider);
  final row = await ref.read(databaseProvider).rosterEntry(chatJid);
  return ContactState(
    subscription: row?.subscription ?? 'none',
    asked: (row?.ask ?? '').isNotEmpty,
  );
});

/// The subset of RFC 6121 subscription state the UI acts on.
class ContactState {
  const ContactState({required this.subscription, required this.asked});

  /// `none`, `to`, `from` or `both`.
  final String subscription;

  /// True when we have asked them and are waiting.
  final bool asked;

  bool get isMutual => subscription == 'both';

  /// One-line description for the user.
  String get summary => switch (subscription) {
        'both' => 'mutual',
        'to' => asked
            ? 'they can see you; your request is pending'
            : 'they can see you; you cannot see them',
        'from' => asked
            ? 'you can see them; your request is pending'
            : 'you can see them; they cannot see you',
        _ => 'not a contact',
      };
}

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
/// The track messages in [chatJid] go out on: the per-conversation override
/// if the user set one, otherwise the global default.
///
/// This is the *choice*, not a negotiated answer and not what the peer
/// supports. Keeping the three apart is the whole point — a value that blended
/// them would silently change what the user asked for whenever a capability
/// lookup came back different.
///
/// The default is [Track.standard]: it is the only track a third-party client
/// can read, and a fresh install that starts on plaintext would hand every new
/// conversation to anyone with access to the server.
final chatTrackProvider =
    FutureProvider.family<Track, String>((ref, chatJid) async {
  // Watched, not just read: the picker and the header have to re-resolve when
  // the global default changes, or they disagree until the next restart.
  final global = ref.watch(globalTrackProvider.future);
  final override = await ref.watch(databaseProvider).trackOverride(chatJid);
  return override ?? await global;
});

/// The override set for [chatJid], or null when there is none.
///
/// Separate from [chatTrackProvider] because "inherits the global default" and
/// "is set to the same value as the global default" are different states: only
/// the first one follows a later change to the default.
final chatTrackOverrideProvider =
    FutureProvider.family<Track?, String>((ref, chatJid) {
  // Invalidated by setChatTrack, so this re-reads after a change.
  return ref.watch(databaseProvider).trackOverride(chatJid);
});

/// The track used by conversations with no override of their own.
final globalTrackProvider = FutureProvider<Track>((ref) async {
  final stored = await ref.read(databaseProvider).metaValue(_globalTrackKey);
  if (stored == null) return Track.standard;
  // A corrupt setting resolves to the standard track, never to plaintext: an
  // unreadable value must not cost the user their encryption.
  return Track.fromStored(stored) ?? Track.standard;
});

/// Stores the global default.
Future<void> setGlobalTrack(WidgetRef ref, Track track) async {
  await ref.read(databaseProvider).setMetaValue(_globalTrackKey, track.stored);
}

/// Pins [chatJid] to [track], or clears the override when null.
Future<void> setChatTrack(WidgetRef ref, String chatJid, Track? track) async {
  final db = ref.read(databaseProvider);
  await db.setTrackOverride(chatJid, track);
  // Leaving plaintext re-arms the warning for next time. Otherwise a user who
  // once confirmed it would never see it again — including on the way back,
  // which is the transition worth a fresh look.
  await db.clearPlaintextAcknowledgement(chatJid);
  ref.invalidate(chatTrackOverrideProvider(chatJid));
  ref.invalidate(chatTrackProvider(chatJid));
}

/// Database key holding the global default track.
const _globalTrackKey = 'global_track';
