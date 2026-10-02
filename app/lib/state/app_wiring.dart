// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';
import '../omemo/track.dart';
import '../store/database.dart';
import '../xmpp/connection.dart';

/// Connects the connection's streams to persistent state for the app's
/// lifetime: delivery receipts, delivery failures and capability
/// invalidation.
///
/// All three used to be wired from whichever page happened to be mounted.
/// A delivery receipt that arrived while the user sat in a conversation was
/// therefore dropped, and the message stayed marked "not delivered" for
/// good. Doing it here means the bookkeeping follows the connection, not the
/// navigation stack.
///
/// The capability service deliberately lives in the widget layer rather than
/// in a provider.
///
/// This deliberately lives in the widget layer rather than in a provider.
/// Doing it in a provider created a cycle the moment the encryption page
/// asked for capabilities: `capabilityServiceProvider` resolves its managers
/// through `dualTrackManagerProvider`, and that provider depended on the
/// wiring provider, which depended on `capabilityServiceProvider` again.
/// Riverpod reported it as a `CircularDependencyError` — a red screen on a
/// real device, invisible to unit tests because they never build two
/// providers that reference each other through a lazy callback.
///
/// Keeping it in the tree also makes the lifetime obvious: the wiring is
/// attached while a widget is mounted and removed when it goes away.
class AppWiring extends ConsumerStatefulWidget {
  const AppWiring({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<AppWiring> createState() => _AppWiringState();
}

class _AppWiringState extends ConsumerState<AppWiring> {
  final List<StreamSubscription<Object?>> _subs = [];

  @override
  void initState() {
    super.initState();
    final xmpp = ref.read(xmppServiceProvider);
    xmpp.attachCapabilities(ref.read(capabilityServiceProvider));
    // A PEP change must drop the cached answer, not wait out the TTL.
    _subs.add(xmpp.capabilityChanges.listen((jid) {
      ref.read(capabilityServiceProvider).invalidate(jid);
    }));
    // XEP-0184: flip our outgoing messages to "delivered".
    _subs.add(xmpp.deliveryReceipts.listen((receipt) {
      unawaited(
        ref.read(databaseProvider).markDelivered(
              receipt.from.toBare().toString(),
              receipt.stanzaId,
            ),
      );
    }));
    // Persist inbound traffic. This used to live in the chat list, so a
    // message that arrived while the user was somewhere else in the app
    // was never written down — a silent data loss that only showed up as a
    // conversation that looked empty when reopened.
    _subs.add(
      xmpp.inbound.listen(
        (msg) => unawaited(storeInbound(ref.read(databaseProvider), msg)),
      ),
    );
  }

  @override
  void dispose() {
    for (final sub in _subs) {
      sub.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}


/// Writes one inbound message into the store.
///
/// Idempotent by stanza id, so a carbon that arrives twice, or a message
/// that is also replayed from the archive, cannot duplicate a bubble.
Future<void> storeInbound(AppDatabase db, InboundMessage msg) async {
  final chatJid = msg.from.toBare().toString();
  await db.upsertChat(chatJid);

  // A carbon duplicates a message we already hold locally.
  if (msg.isCarbonCopy) return;
  final stanzaId = msg.stanzaId ?? '';
  if (await db.findByStanzaId(chatJid, stanzaId) != null) return;

  await db.insertMessage(
    MessagesCompanion(
      chatJid: Value(chatJid),
      sender: Value(msg.from.toString()),
      stanzaId: Value(stanzaId),
      // Never store the ciphertext of something we could not open: the
      // placeholder carries the failure, not the payload.
      body: Value(msg.encryptionError != null ? '' : msg.body),
      timestamp: Value(msg.archiveTimestamp ?? DateTime.now()),
      encMode: Value(
        // A message we could not open is a condition, not a track: the UI has
        // to say "this was encrypted, but not by us", and "none" would say
        // the opposite.
        msg.encryptionError != null
            ? EncModeToken.error.wire
            : EncModeToken.of(msg.track ?? Track.none).wire,
      ),
      incoming: const Value(true),
    ),
  );
}
