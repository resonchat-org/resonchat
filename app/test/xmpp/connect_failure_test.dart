// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The login screen used to render whichever error `XmppConnection.connect`
// happened to return. moxxmpp's errors define no `toString()`, so a user whose
// server was simply unreachable was shown `Instance of
// 'NoConnectionPossibleError'`, and because that string was never null the
// screen's own "authentication failed" fallback could never appear. These tests
// pin the classification down: each failure must land on the reason a person can
// actually act on, and the messages must not collapse into one another.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moxxmpp/moxxmpp.dart';
import 'package:resonchat/l10n/connect_failure_label.dart';
import 'package:resonchat/l10n/l10n.dart';
import 'package:resonchat/xmpp/connect_failure.dart';

XmppError _socketError() =>
    SocketError(XmppSocketErrorEvent(Exception('connection refused')));

void main() {
  group('classifyConnectFailure', () {
    test('a server that cannot be reached is "unreachable", not a bad password', () {
      // The exact error from the bug report.
      expect(
        classifyConnectFailure(NoConnectionPossibleError()),
        XmppConnectFailure.unreachable,
      );
    });

    test('socket-level failures are unreachable', () {
      expect(
        classifyConnectFailure(StreamFailureError(_socketError())),
        XmppConnectFailure.unreachable,
      );
      expect(
        classifyConnectFailure(StreamFailureError(TimeoutError())),
        XmppConnectFailure.unreachable,
      );
    });

    test('a refused SASL exchange is an authentication failure', () {
      expect(
        classifyConnectFailure(
          NegotiatorReturnedError(SaslNotAuthorizedError()),
        ),
        XmppConnectFailure.auth,
      );
      // Even the unnamed SASL error means "the server did not accept us";
      // reporting it as unreachable would send the user to fix their network.
      expect(
        classifyConnectFailure(NegotiatorReturnedError(SaslUnspecifiedError())),
        XmppConnectFailure.auth,
      );
    });

    test('a failed TLS handshake is its own reason', () {
      expect(
        classifyConnectFailure(NegotiatorReturnedError(StartTLSFailedError())),
        XmppConnectFailure.tls,
      );
    });

    test('no usable mechanism is a server problem, not a credentials one', () {
      expect(
        classifyConnectFailure(
          NegotiatorReturnedError(NoSASLMechanismSelectedError()),
        ),
        XmppConnectFailure.mechanism,
      );
      expect(
        classifyConnectFailure(NoMatchingAuthenticationMechanismAvailableError()),
        XmppConnectFailure.mechanism,
      );
      expect(
        classifyConnectFailure(NoAuthenticatorAvailableError()),
        XmppConnectFailure.mechanism,
      );
    });

    test('a broken protocol conversation is distinct from all of the above', () {
      expect(
        classifyConnectFailure(StreamFailureError(StreamError())),
        XmppConnectFailure.protocol,
      );
      expect(
        classifyConnectFailure(UnexpectedDataError()),
        XmppConnectFailure.protocol,
      );
      expect(
        classifyConnectFailure(InvalidHandshakeCredentialsError()),
        XmppConnectFailure.protocol,
      );
      expect(
        classifyConnectFailure(
          NegotiatorReturnedError(ResourceBindingFailedError()),
        ),
        XmppConnectFailure.protocol,
      );
    });

    test('an unrecognised error stays unrecognised', () {
      // Not every XmppError is one we can name. Saying so beats inventing a
      // cause, which is what the old string interpolation did.
      expect(
        classifyConnectFailure(
          NegotiatorReturnedError(_AnonymousNegotiatorError()),
        ),
        XmppConnectFailure.unknown,
      );
    });
  });

  group('connectFailureLabel', () {
    late AppLocalizations en;

    setUp(() async {
      en = await AppLocalizations.delegate.load(const Locale('en'));
    });

    test('every reason has words of its own', () {
      final labels = <XmppConnectFailure, String>{
        for (final f in XmppConnectFailure.values)
          f: connectFailureLabel(en, f),
      };
      for (final entry in labels.entries) {
        expect(entry.value.trim(), isNotEmpty, reason: '${entry.key} is silent');
      }
      // The whole point: "unreachable" must not read like "wrong password".
      expect(
        labels[XmppConnectFailure.unreachable],
        isNot(labels[XmppConnectFailure.auth]),
      );
      expect(
        labels[XmppConnectFailure.mechanism],
        isNot(labels[XmppConnectFailure.auth]),
      );
      // Distinct reasons must stay distinct — collapsing them would hide which
      // one actually happened.
      expect(labels.values.toSet().length, labels.length);
    });

    test('an unknown reason reads as a plain connect failure', () {
      expect(
        connectFailureLabel(en, XmppConnectFailure.unknown),
        en.connectFailed,
      );
      // No reason recorded is the same situation as an unnamed one.
      expect(connectFailureLabel(en, null), en.connectFailed);
    });
  });
}

/// A negotiator error with no case of its own, used to exercise the fallback.
class _AnonymousNegotiatorError extends NegotiatorError {
  @override
  bool isRecoverable() => true;
}
