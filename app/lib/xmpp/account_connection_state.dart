// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Conversations-style account connection states that drive reconnect.

import 'package:resonchat/xmpp/connect_failure.dart';

/// Fine-grained account connection state (Conversations Account.state subset).
enum AccountConnectionState {
  online,
  connecting,
  offline,
  noInternet,
  unreachable,
  unauthorized,
  tlsError,
  incompatibleServer,
  policyViolation,
  seeOtherHost,
  connectionTimeout,
  streamError,
  bindFailure,
}

/// Whether [state] should be retried by [AccountConnectionController].
bool attemptReconnect(AccountConnectionState state) {
  switch (state) {
    case AccountConnectionState.online:
    case AccountConnectionState.connecting:
    case AccountConnectionState.unauthorized:
    case AccountConnectionState.incompatibleServer:
      return false;
    case AccountConnectionState.offline:
    case AccountConnectionState.noInternet:
    case AccountConnectionState.unreachable:
    case AccountConnectionState.tlsError:
    case AccountConnectionState.policyViolation:
    case AccountConnectionState.seeOtherHost:
    case AccountConnectionState.connectionTimeout:
    case AccountConnectionState.streamError:
    case AccountConnectionState.bindFailure:
      return true;
  }
}

/// Immediate reconnect (no backoff wait), matching Conversations OFFLINE /
/// ping-timeout behaviour.
bool reconnectImmediately(AccountConnectionState state) {
  return state == AccountConnectionState.offline;
}

/// Conversations aggressive backoff: SEE_OTHER_HOST **or** an active Jingle RTP
/// call ([hasActiveJingleRtpCall]). Unrelated to Push.
bool isAggressiveReconnect(
  AccountConnectionState state, {
  bool hasActiveJingleRtpCall = false,
}) {
  return state == AccountConnectionState.seeOtherHost || hasActiveJingleRtpCall;
}

bool isPolicyViolationBackoff(AccountConnectionState state) {
  return state == AccountConnectionState.policyViolation;
}

/// Maps a classified connect failure onto an account state.
AccountConnectionState accountStateFromConnectFailure(
  XmppConnectFailure failure,
) {
  switch (failure) {
    case XmppConnectFailure.unreachable:
      return AccountConnectionState.unreachable;
    case XmppConnectFailure.auth:
      return AccountConnectionState.unauthorized;
    case XmppConnectFailure.tls:
      return AccountConnectionState.tlsError;
    case XmppConnectFailure.mechanism:
      return AccountConnectionState.incompatibleServer;
    case XmppConnectFailure.protocol:
      return AccountConnectionState.streamError;
    case XmppConnectFailure.unknown:
      return AccountConnectionState.unreachable;
  }
}
