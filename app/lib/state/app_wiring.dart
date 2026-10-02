// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';

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
