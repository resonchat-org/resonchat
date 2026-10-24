// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// moxxmpp reconnection policies used by ResonChat.
//
// Automatic reconnect after stream loss is owned by
// [AccountConnectionController] (Conversations manageAccountConnectionStates).
// Production connections therefore use [NeverReconnectPolicy] so moxxmpp never
// schedules a parallel backoff clock.

import 'package:moxxmpp/moxxmpp.dart';

/// Reconnection policy that never reconnects.
///
/// Used for the app session (controller reconnects) and for probes / tools
/// where an automatic reconnect would bury the caller's measurement.
class NeverReconnectPolicy extends ReconnectionPolicy {
  @override
  Future<void> onSuccess() async {}

  @override
  Future<void> onFailure() async {}
}
