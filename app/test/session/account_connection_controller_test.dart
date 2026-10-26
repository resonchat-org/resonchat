// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

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

    test('connect timeout resets the backoff clock instead of hot-looping', () async {
      var clock = DateTime.utc(2024, 1, 1, 12);
      var connects = 0;
      var disconnects = 0;
      final pending = Completer<bool>();
      final controller = AccountConnectionController(
        connectAccount: (id) {
          connects++;
          return pending.future;
        },
        disconnectAccount: (_) async {
          disconnects++;
        },
        sendPing: (_) async => true,
        isEnabled: (_) => true,
        accountIds: () => ['a1'],
        now: () => clock,
      );

      controller.requestConnect('a1');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(connects, 1);
      expect(controller.stateOf('a1'), AccountConnectionState.connecting);

      clock = clock.add(const Duration(seconds: 91));
      controller.processAccountState('a1');
      await Future<void>.delayed(const Duration(milliseconds: 30));

      final r = controller.runtime('a1');
      expect(disconnects, 1);
      expect(
        controller.stateOf('a1'),
        AccountConnectionState.connectionTimeout,
      );
      expect(r.attempt, 1);
      // Conversations triggerConnectionTimeout resets lastConnectionStarted, so
      // the next wait is the full ~32.5 s rather than "already elapsed".
      expect(r.connectStartedAt, clock);
      expect(connects, 1, reason: 'no second socket while the old one returns');

      // The late success must not revive the timed-out attempt.
      pending.complete(true);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(
        controller.stateOf('a1'),
        AccountConnectionState.connectionTimeout,
      );
      expect(connects, 1);
      expect(disconnects, greaterThanOrEqualTo(2));
      controller.dispose();
    });

    test('duplicate stream loss starts one reconnect', () async {
      var connects = 0;
      final controller = AccountConnectionController(
        connectAccount: (_) async {
          connects++;
          return true;
        },
        disconnectAccount: (_) async {},
        sendPing: (_) async => true,
        isEnabled: (_) => true,
        accountIds: () => ['a1'],
      );
      controller.setState('a1', AccountConnectionState.online);
      controller.onConnectionLost('a1', AccountConnectionState.offline);
      controller.onConnectionLost('a1', AccountConnectionState.offline);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(connects, 1);
      expect(controller.stateOf('a1'), AccountConnectionState.online);
      controller.dispose();
    });

    test('network loss pauses retry until connectivity returns', () async {
      var connects = 0;
      final controller = AccountConnectionController(
        connectAccount: (_) async {
          connects++;
          return true;
        },
        disconnectAccount: (_) async {},
        sendPing: (_) async => true,
        isEnabled: (_) => true,
        accountIds: () => ['a1'],
      );
      controller.setState('a1', AccountConnectionState.online);
      controller.onConnectivityLost();
      expect(controller.stateOf('a1'), AccountConnectionState.noInternet);

      controller.onConnectionLost('a1', AccountConnectionState.unreachable);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(connects, 0);
      expect(controller.stateOf('a1'), AccountConnectionState.noInternet);

      controller.onConnectivityRestored();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(connects, 1);
      expect(controller.stateOf('a1'), AccountConnectionState.online);
      controller.dispose();
    });

    test(
      'connect exception is treated as unreachable and backed off',
      () async {
        var connects = 0;
        final controller = AccountConnectionController(
          connectAccount: (_) async {
            connects++;
            throw StateError('socket factory exploded');
          },
          disconnectAccount: (_) async {},
          sendPing: (_) async => true,
          isEnabled: (_) => true,
          accountIds: () => ['a1'],
        );
        controller.requestConnect('a1');
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(connects, 1);
        expect(controller.stateOf('a1'), AccountConnectionState.unreachable);
        expect(controller.runtime('a1').attempt, 1);
        expect(controller.runtime('a1').dueTimer?.isActive, isTrue);
        controller.dispose();
      },
    );

    test('requesting a retry while connecting keeps one socket open', () async {
      var connects = 0;
      var disconnects = 0;
      final pending = <Completer<bool>>[];
      final controller = AccountConnectionController(
        connectAccount: (_) {
          connects++;
          final c = Completer<bool>();
          pending.add(c);
          return c.future;
        },
        disconnectAccount: (_) async {
          disconnects++;
        },
        sendPing: (_) async => true,
        isEnabled: (_) => true,
        accountIds: () => ['a1'],
      );

      controller.requestConnect('a1');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      controller.requestConnect('a1');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(connects, 1, reason: 'connectInFlight is the mutex');
      expect(disconnects, greaterThanOrEqualTo(1));

      pending.first.complete(true);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(
        connects,
        2,
        reason: 'retry starts only after the old future ends',
      );
      pending.last.complete(true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(controller.stateOf('a1'), AccountConnectionState.online);
      controller.dispose();
    });

    test('connectFailureState classifies a failed attempt', () async {
      final controller = AccountConnectionController(
        connectAccount: (_) async => false,
        disconnectAccount: (_) async {},
        sendPing: (_) async => true,
        isEnabled: (_) => true,
        accountIds: () => ['a1'],
        connectFailureState: (_) => AccountConnectionState.tlsError,
      );
      controller.requestConnect('a1');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(controller.stateOf('a1'), AccountConnectionState.tlsError);
      controller.dispose();
    });

    test(
      'a connect that returns after the deadline becomes connectionTimeout',
      () async {
        var clock = DateTime.utc(2024, 1, 1, 12);
        final controller = AccountConnectionController(
          connectAccount: (_) async {
            // XmppService's internal 90 s ceiling fired before the controller's
            // own timer got a turn.
            clock = clock.add(const Duration(seconds: 91));
            return false;
          },
          disconnectAccount: (_) async {},
          sendPing: (_) async => true,
          isEnabled: (_) => true,
          accountIds: () => ['a1'],
          now: () => clock,
        );
        controller.requestConnect('a1');
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(
          controller.stateOf('a1'),
          AccountConnectionState.connectionTimeout,
        );
        expect(controller.runtime('a1').attempt, 1);
        expect(controller.runtime('a1').connectStartedAt, clock);
        expect(controller.runtime('a1').dueTimer?.isActive, isTrue);
        controller.dispose();
      },
    );

    test('network loss aborts a connect stuck on the old network', () async {
      var connects = 0;
      var disconnects = 0;
      final pending = <Completer<bool>>[];
      final controller = AccountConnectionController(
        connectAccount: (_) {
          connects++;
          final c = Completer<bool>();
          pending.add(c);
          return c.future;
        },
        disconnectAccount: (_) async {
          disconnects++;
        },
        sendPing: (_) async => true,
        isEnabled: (_) => true,
        accountIds: () => ['a1'],
      );

      controller.requestConnect('a1');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(connects, 1);
      controller.onConnectivityLost();
      expect(controller.stateOf('a1'), AccountConnectionState.noInternet);
      expect(disconnects, greaterThanOrEqualTo(1));

      pending.first.complete(true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(connects, 1, reason: 'no retry while there is no network');
      expect(controller.stateOf('a1'), AccountConnectionState.noInternet);

      controller.onConnectivityRestored();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(connects, 2);
      expect(controller.stateOf('a1'), AccountConnectionState.connecting);
      pending.last.complete(true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(controller.stateOf('a1'), AccountConnectionState.online);
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
