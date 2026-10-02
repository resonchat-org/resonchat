// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';

/// Connects the capability service to the connection for the app's lifetime.
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
class CapabilityWiring extends ConsumerStatefulWidget {
  const CapabilityWiring({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<CapabilityWiring> createState() => _CapabilityWiringState();
}

class _CapabilityWiringState extends ConsumerState<CapabilityWiring> {
  StreamSubscription<Object?>? _sub;

  @override
  void initState() {
    super.initState();
    final xmpp = ref.read(xmppServiceProvider);
    xmpp.attachCapabilities(ref.read(capabilityServiceProvider));
    // A PEP change must drop the cached answer, not wait out the TTL.
    _sub = xmpp.capabilityChanges.listen((jid) {
      ref.read(capabilityServiceProvider).invalidate(jid);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
