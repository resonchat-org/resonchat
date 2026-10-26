// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:test/test.dart';

import 'package:resonchat/xmpp/account_connection_state.dart';
import 'package:resonchat/xmpp/connect_failure.dart';

void main() {
  test('classify mapping covers every XmppConnectFailure', () {
    for (final f in XmppConnectFailure.values) {
      final state = accountStateFromConnectFailure(f);
      expect(state, isNot(AccountConnectionState.online));
      expect(state, isNot(AccountConnectionState.connecting));
    }
  });

  test('auth and mechanism never attempt reconnect', () {
    expect(
      attemptReconnect(accountStateFromConnectFailure(XmppConnectFailure.auth)),
      isFalse,
    );
    expect(
      attemptReconnect(
        accountStateFromConnectFailure(XmppConnectFailure.mechanism),
      ),
      isFalse,
    );
  });

  test('aggressive includes SEE_OTHER_HOST and active Jingle RTP', () {
    expect(isAggressiveReconnect(AccountConnectionState.seeOtherHost), isTrue);
    expect(
      isAggressiveReconnect(
        AccountConnectionState.unreachable,
        hasActiveJingleRtpCall: true,
      ),
      isTrue,
    );
    expect(isAggressiveReconnect(AccountConnectionState.unreachable), isFalse);
  });
}
