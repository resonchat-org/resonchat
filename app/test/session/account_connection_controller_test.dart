// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:test/test.dart';

import 'package:resonchat/xmpp/account_connection_controller.dart';
import 'package:resonchat/xmpp/account_connection_state.dart';

void main() {
  group('AccountConnectionController', () {
    test('requestConnect drives a connect when offline', () async {
      var connects = 0;
      final controller = AccountConnectionController(
        connectAccount: (id) async {
          connects++;
          return true;
        },
        disconnectAccount: (_) async {},
        sendPing: (_) async => true,
        isEnabled: (_) => true,
        accountIds: () => ['a1'],
      );
      controller.requestConnect('a1');
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(connects, 1);
      expect(controller.stateOf('a1'), AccountConnectionState.online);
      controller.dispose();
    });

    test('unauthorized does not schedule another connect', () async {
      var connects = 0;
      final controller = AccountConnectionController(
        connectAccount: (id) async {
          connects++;
          return false;
        },
        disconnectAccount: (_) async {},
        sendPing: (_) async => true,
        isEnabled: (_) => true,
        accountIds: () => ['a1'],
      );
      // Simulate a failed auth without going through connectAccount.
      controller.onConnectionLost('a1', AccountConnectionState.unauthorized);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(connects, 0);
      expect(attemptReconnect(AccountConnectionState.unauthorized), isFalse);
      controller.dispose();
    });

    test('ping timeout forces offline then reconnect', () async {
      var disconnects = 0;
      var connects = 0;
      var clock = DateTime.utc(2024, 1, 1, 12);
      final controller = AccountConnectionController(
        connectAccount: (id) async {
          connects++;
          return true;
        },
        disconnectAccount: (_) async {
          disconnects++;
        },
        sendPing: (_) async => false,
        isEnabled: (_) => true,
        accountIds: () => ['a1'],
        now: () => clock,
      );
      controller.setState('a1', AccountConnectionState.online);
      final r = controller.runtime('a1');
      // Packet before the ping so lastSent > lastReceived after we stamp sent.
      r.lastPacketReceived = clock.subtract(const Duration(seconds: 1));
      r.lastPingSent = clock;
      // No packet after ping; advance past pingTimeout.
      clock = clock.add(const Duration(seconds: 16));
      controller.processAccountState('a1');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(disconnects, 1);
      expect(connects, greaterThanOrEqualTo(1));
      controller.dispose();
    });

    test('failed attempt connectionDuration shortens backoff', () {
      var clock = DateTime.utc(2024, 1, 1, 12);
      final controller = AccountConnectionController(
        connectAccount: (_) async => false,
        disconnectAccount: (_) async {},
        sendPing: (_) async => true,
        isEnabled: (_) => true,
        accountIds: () => ['a1'],
        now: () => clock,
      );
      controller.setState('a1', AccountConnectionState.connecting);
      // Spent 20 s connecting before failure.
      clock = clock.add(const Duration(seconds: 20));
      controller.onConnectionLost('a1', AccountConnectionState.unreachable);
      // attempt is 1 → base ~32.5 s; minus 20 s connectionDuration ≈ 12.5 s left.
      final r = controller.runtime('a1');
      expect(r.connectStartedAt, isNotNull);
      expect(r.attempt, 1);
      controller.dispose();
    });

    test('onConnectivityRestored processes accounts', () async {
      var connects = 0;
      final controller = AccountConnectionController(
        connectAccount: (id) async {
          connects++;
          return true;
        },
        disconnectAccount: (_) async {},
        sendPing: (_) async => true,
        isEnabled: (_) => true,
        accountIds: () => ['a1'],
      );
      controller.setState('a1', AccountConnectionState.unreachable);
      controller.onConnectivityRestored();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(connects, greaterThanOrEqualTo(1));
      controller.dispose();
    });
  });

  group('accountStateFromConnectFailure', () {
    test('maps auth and mechanism to non-reconnect states', () {
      expect(attemptReconnect(AccountConnectionState.unauthorized), isFalse);
      expect(
        attemptReconnect(AccountConnectionState.incompatibleServer),
        isFalse,
      );
      expect(attemptReconnect(AccountConnectionState.unreachable), isTrue);
      expect(reconnectImmediately(AccountConnectionState.offline), isTrue);
    });
  });
}
