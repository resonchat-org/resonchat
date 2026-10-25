// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:test/test.dart';

import 'package:resonchat/xmpp/account_share_uri.dart';

void main() {
  final fp = '05${'ab' * 32}';
  final stripped = 'ab' * 32;

  test('bare address when there is no fingerprint yet', () {
    expect(
      accountShareUri(bareJid: 'user@example.com'),
      'xmpp:user@example.com',
    );
  });

  test('light-escapes only # and % in the JID', () {
    expect(
      accountShareUri(bareJid: 'a#b%c@example.com'),
      'xmpp:a%23b%25c@example.com',
    );
  });

  test('own device is omemo-sid with the unspaced fingerprint', () {
    expect(
      accountShareUri(
        bareJid: 'user@example.com',
        deviceId: 123456,
        legacyFingerprint: fp,
      ),
      'xmpp:user@example.com?omemo-sid-123456=$stripped',
    );
  });

  test('verified own devices follow, separated by ;', () {
    expect(
      accountShareUri(
        bareJid: 'user@example.com',
        deviceId: 1,
        legacyFingerprint: '05${'aa' * 32}',
        verifiedOwnDevices: [(deviceId: 2, fingerprint: '05${'bb' * 32}')],
      ),
      'xmpp:user@example.com?omemo-sid-1=${'aa' * 32};omemo-sid-2=${'bb' * 32}',
    );
  });

  test('room join URI is xmpp:jid?join', () {
    expect(
      roomJoinUri('room@conference.example'),
      'xmpp:room@conference.example?join',
    );
    expect(
      roomJoinUri('a#b@conference.example'),
      'xmpp:a%23b@conference.example?join',
    );
  });

  test('parseOmemoSidFingerprints keeps valid 64-hex pairs', () {
    final parsed = parseOmemoSidFingerprints({
      'omemo-sid-7': stripped,
      'omemo-sid-notanumber': stripped,
      'omemo-sid-0': stripped,
      'body': 'hi',
      'omemo-sid-2': '05$stripped',
      'omemo-sid-3': 'zz' * 32,
    });
    expect(parsed, [(deviceId: 7, fingerprint: stripped)]);
  });

  test('fingerprintForTrustStore restores the 05 type byte', () {
    expect(fingerprintForTrustStore(stripped), fp);
    expect(fingerprintForTrustStore(fp), fp);
  });
}
