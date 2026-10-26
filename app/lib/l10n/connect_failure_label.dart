// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:resonchat/l10n/generated/app_localizations.dart';
import 'package:resonchat/xmpp/connect_failure.dart';

/// The sentence shown when a connection attempt fails with [failure].
///
/// `null` means no classified failure was recorded — which is itself a fact,
/// and is reported as the generic "could not connect" rather than dressed up
/// as something more specific.
///
/// Deliberately exhaustive over [XmppConnectFailure]: adding a case must make
/// this fail to compile rather than fall through to a generic "something went
/// wrong", which is how a user ends up unable to tell a typo in their password
/// from an unreachable server.
String connectFailureLabel(AppLocalizations l10n, XmppConnectFailure? failure) {
  switch (failure) {
    case null:
    case XmppConnectFailure.unknown:
      return l10n.connectFailed;
    case XmppConnectFailure.auth:
      return l10n.authenticationFailed;
    case XmppConnectFailure.unreachable:
      return l10n.connectUnreachable;
    case XmppConnectFailure.tls:
      return l10n.connectTls;
    case XmppConnectFailure.mechanism:
      return l10n.connectMechanism;
    case XmppConnectFailure.protocol:
      return l10n.connectProtocol;
  }
}
