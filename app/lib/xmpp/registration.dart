// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// XEP-0077 in-band registration (Conversations RegistrationManager path).
// Opens a short-lived connection with no SASL, runs IBR, disconnects.
// The caller then logs in normally.

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:moxxmpp/moxxmpp.dart';

import 'package:resonchat/net/app_network.dart';
import 'package:resonchat/xmpp/socket/xmpp_socket.dart';

/// No automatic reconnect — registration is a one-shot socket.
class _NoReconnectPolicy extends ReconnectionPolicy {
  @override
  Future<void> onSuccess() async {}

  @override
  Future<void> onFailure() async {}
}

final _log = Logger('Registration');

/// Outcome of [registerAccount].
class RegisterAccountResult {
  const RegisterAccountResult._({
    this.success = false,
    this.error,
    this.redirectUrl,
  });

  const RegisterAccountResult.ok() : this._(success: true);

  const RegisterAccountResult.fail(String error) : this._(error: error);

  const RegisterAccountResult.redirect(Uri url)
    : this._(error: 'redirect', redirectUrl: url);

  final bool success;
  final String? error;
  final Uri? redirectUrl;
}

/// Public providers list (Copinc `available_domains`) — all treated equally.
/// Default queue for the registration UI; not fetched until the user asks.
const kPublicXmppProviders = <String>[
  'monocles.de',
  'monocles.eu',
  'draugr.de',
  'deshalbfrei.org',
  'ubuntu-jabber.de',
  'ubuntu-jabber.net',
  'verdammung.org',
  'xabber.de',
  'nixnet.services',
  'paranoid.network',
  'linux.monster',
  'pwned.life',
  'redlibre.es',
  'projectsegfau.lt',
  'xmpp.party',
  'yax.im',
];

/// Gajim `providers_list_url` default — category B (suitable for automatic
/// registration UIs). Fetched only when the user taps the register-page button.
const kXmppProvidersListUrl =
    'https://data.xmpp.net/providers/v2/providers-B.json';

/// Parse a providers-v2 JSON body into unique lowercase domain JIDs.
List<String> parseXmppProvidersJson(String body) {
  final decoded = jsonDecode(body);
  if (decoded is! List) {
    throw const FormatException('providers list is not an array');
  }
  final out = <String>[];
  final seen = <String>{};
  for (final item in decoded) {
    if (item is! Map) continue;
    final jid = item['jid'];
    if (jid is! String) continue;
    final domain = jid.trim().toLowerCase();
    if (domain.isEmpty || !seen.add(domain)) continue;
    out.add(domain);
  }
  return out;
}

/// Download [kXmppProvidersListUrl] (or [url]) and return domain JIDs.
///
/// Uses [appNetwork] so SOCKS5 applies the same as other app HTTP. Does not
/// fall back to [kPublicXmppProviders] — callers replace their queue on
/// success and keep the previous list on failure.
Future<List<String>> fetchPublicXmppProviders({
  http.Client? client,
  Uri? url,
  Duration timeout = const Duration(seconds: 20),
}) async {
  await appNetwork.waitUntilReady();
  final httpClient = client ?? appNetwork.createHttpClient();
  final owned = client == null;
  try {
    final resp = await httpClient
        .get(url ?? Uri.parse(kXmppProvidersListUrl))
        .timeout(timeout);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw StateError('HTTP ${resp.statusCode}');
    }
    final list = parseXmppProvidersJson(resp.body);
    if (list.isEmpty) {
      throw StateError('empty providers list');
    }
    return list;
  } finally {
    if (owned) httpClient.close();
  }
}

/// Run XEP-0077 registration, then disconnect.
///
/// [onCaptcha] is called when the server returns a captcha form; return the
/// OCR text, or null to cancel.
Future<RegisterAccountResult> registerAccount({
  required String jid,
  required String password,
  String? host,
  int? port,
  Future<String?> Function(ExtendedRegistration challenge)? onCaptcha,
  String registrationFailedLabel = 'Registration failed',
  String registrationNotSupportedLabel =
      'This server does not allow registration',
  String registrationConflictLabel = 'That username is already taken',
  String registrationPasswordWeakLabel = 'Password is too weak',
  String registrationCaptchaLabel = 'Captcha was incorrect',
  String registrationPleaseWaitLabel = 'Please wait and try again',
}) async {
  await appNetwork.waitUntilReady();

  final bare = JID.fromString(jid.trim()).toBare();
  final websocketOverride =
      (host != null && (host.startsWith('wss:') || host.startsWith('ws:')))
      ? host
      : null;

  final ibr = InBandRegistrationNegotiator();
  final connection =
      XmppConnection(
          _NoReconnectPolicy(),
          AlwaysConnectedConnectivityManager(),
          ClientToServerNegotiator(),
          createXmppSocket(websocketUrl: websocketOverride),
        )
        ..connectionSettings = ConnectionSettings(
          jid: bare,
          password: password,
          host: websocketOverride != null ? null : host,
          port: websocketOverride != null
              ? null
              : (port ?? (host != null && host.isNotEmpty ? 5222 : null)),
          register: true,
        );

  // No post-auth managers: this socket exists only for IBR, then dies.
  await connection.registerManagers([]);
  await connection.registerFeatureNegotiators([StartTlsNegotiator(), ibr]);

  var cancelled = false;
  final captchaJob = ibr.challenge.then((challenge) async {
    if (challenge is ExtendedRegistration) {
      final ocr = onCaptcha == null ? null : await onCaptcha(challenge);
      if (ocr == null || ocr.trim().isEmpty) {
        cancelled = true;
        await connection.disconnect();
        return;
      }
      await ibr.submitCaptcha(ocr.trim());
    }
  });

  _log.info('registering ${bare.toString()}');
  final result = await connection.connect(
    shouldReconnect: false,
    waitUntilLogin: true,
    enableReconnectOnSuccess: false,
  );
  // Captcha job may still be running if we disconnected early.
  try {
    await captchaJob;
  } catch (_) {}

  await connection.disconnect();

  if (cancelled) {
    return RegisterAccountResult.fail(registrationFailedLabel);
  }

  if (result.isType<bool>() && result.get<bool>()) {
    // Negotiations completed without hitting RegistrationSuccessful —
    // unexpected for register:true (no SASL registered).
    return RegisterAccountResult.fail(registrationFailedLabel);
  }

  final err = result.isType<XmppError>() ? result.get<XmppError>() : null;
  final nested = err is NegotiatorReturnedError ? err.error : err;

  if (nested is RegistrationSuccessful) {
    return const RegisterAccountResult.ok();
  }
  if (nested is RegistrationNotSupportedError) {
    return RegisterAccountResult.fail(registrationNotSupportedLabel);
  }
  if (nested is RegistrationFailedError) {
    if (nested.redirectUrl != null) {
      return RegisterAccountResult.redirect(nested.redirectUrl!);
    }
    if (nested.conflict) {
      return RegisterAccountResult.fail(registrationConflictLabel);
    }
    if (nested.passwordTooWeak) {
      return RegisterAccountResult.fail(registrationPasswordWeakLabel);
    }
    if (nested.invalidCaptcha) {
      return RegisterAccountResult.fail(registrationCaptchaLabel);
    }
    if (nested.pleaseWait) {
      return RegisterAccountResult.fail(registrationPleaseWaitLabel);
    }
    final detail = nested.text.isNotEmpty ? nested.text : '$nested';
    return RegisterAccountResult.fail('$registrationFailedLabel: $detail');
  }

  return RegisterAccountResult.fail(
    err != null ? '$registrationFailedLabel: $err' : registrationFailedLabel,
  );
}
