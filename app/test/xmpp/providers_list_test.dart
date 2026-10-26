// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';

import 'package:resonchat/xmpp/registration.dart';

void main() {
  test('parseXmppProvidersJson extracts unique lowercase jids', () {
    const body = '''
[
  {"jid": "Yax.im", "serverLocations": ["DE"]},
  {"jid": "yax.im", "serverLocations": ["DE"]},
  {"jid": "  jabber.fr ", "serverLocations": ["FR"]},
  {"not": "a provider"},
  "skip-me"
]
''';
    expect(parseXmppProvidersJson(body), ['yax.im', 'jabber.fr']);
  });

  test('parseXmppProvidersJson rejects non-array', () {
    expect(
      () => parseXmppProvidersJson('{"jid":"yax.im"}'),
      throwsA(isA<FormatException>()),
    );
  });
}
