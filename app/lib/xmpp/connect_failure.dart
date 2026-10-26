// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Why a connection attempt failed, in terms the UI can act on.
//
// moxxmpp's error classes define no `toString()`, so interpolating one yields
// `Instance of 'NoConnectionPossibleError'` — which is literally what the login
// screen used to show. The damage was worse than ugly text: *every* failure
// produced a non-null string, so the screen's own localized
// "authentication failed" fallback was dead code. A wrong password and an
// unreachable server looked identical, and neither told a person anything they
// could do.
//
// This is deliberately a pure function over an error object. The wording lives
// in the UI, where it can be localized (see `failureLabel`), and the
// classification can be unit-tested without opening a socket.

import 'package:moxxmpp/moxxmpp.dart';

/// A failed connection attempt, grouped by what the user can do about it.
enum XmppConnectFailure {
  /// The server was never reached: DNS, TCP, the socket-level TLS handshake,
  /// or a timeout. Nothing is known about the credentials, so nothing should
  /// be said about them.
  unreachable,

  /// The server was reached and answered, and refused the credentials.
  auth,

  /// The server was reached, but the encrypted stream could not be set up.
  tls,

  /// The server was reached and offers no authentication mechanism we can
  /// speak — a server-side configuration problem, not a password problem.
  mechanism,

  /// The server was reached and the protocol conversation broke down:
  /// unexpected data, a stream error, or a failed resource bind.
  protocol,

  /// A failure this app cannot name. Saying so is the point; inventing a cause
  /// here would send the user to fix the wrong thing.
  unknown,
}

/// Classifies [error] as returned by `XmppConnection.connect`.
XmppConnectFailure classifyConnectFailure(XmppError error) {
  if (error is NegotiatorReturnedError) {
    return _classifyNegotiatorError(error.error);
  }
  // A negotiator error also comes back *bare*. Seen on device: connecting to a
  // STARTTLS server returned a plain `StartTLSFailedError`, not the wrapper
  // above, and it fell all the way through to `unknown` — the login screen said
  // "Could not connect." for what is really "the encrypted stream could not be
  // set up". [NegotiatorError] extends [XmppError] directly, so the checks
  // below never matched it.
  if (error is NegotiatorError) {
    return _classifyNegotiatorError(error);
  }
  if (error is StreamFailureError) {
    return _classifyBaseError(error.error);
  }

  if (error is NoConnectionPossibleError) return XmppConnectFailure.unreachable;

  // The server answered, so we know it is reachable; what it answered is that
  // it has nothing we can authenticate with. That is not a password problem
  // and must not be reported as one.
  if (error is NoMatchingAuthenticationMechanismAvailableError ||
      error is NoAuthenticatorAvailableError) {
    return XmppConnectFailure.mechanism;
  }

  if (error is UnexpectedDataError ||
      error is InvalidHandshakeCredentialsError) {
    return XmppConnectFailure.protocol;
  }

  return _classifyBaseError(error);
}

XmppConnectFailure _classifyNegotiatorError(NegotiatorError error) {
  // The whole SASL family is an authentication outcome — that is what SASL
  // decides. The named ones below are the cases a user can act on; the
  // unspecified one still means "the server did not accept us".
  if (error is SaslError) return XmppConnectFailure.auth;

  // SCRAM's own failures are *not* [SaslError]s: `SaslScramError` extends
  // [NegotiatorError] directly, so without this they fall to `unknown`.
  //
  //  * a server signature that does not verify means the password did not
  //    derive the key the server holds — check the password.
  //  * missing SASL2 additional-data means the server skipped a step SASL2
  //    requires: the credentials were never contradicted.
  if (error is InvalidServerSignatureError) return XmppConnectFailure.auth;
  if (error is NoAdditionalDataError) return XmppConnectFailure.protocol;

  if (error is StartTLSFailedError) return XmppConnectFailure.tls;

  if (error is NoSASLMechanismSelectedError) {
    return XmppConnectFailure.mechanism;
  }

  if (error is ResourceBindingFailedError) return XmppConnectFailure.protocol;

  return XmppConnectFailure.unknown;
}

XmppConnectFailure _classifyBaseError(XmppError error) {
  if (error is SocketError || error is TimeoutError) {
    return XmppConnectFailure.unreachable;
  }
  if (error is StreamError) return XmppConnectFailure.protocol;
  return XmppConnectFailure.unknown;
}
