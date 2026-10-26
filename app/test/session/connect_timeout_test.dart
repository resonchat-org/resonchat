// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:test/test.dart';

import 'package:resonchat/xmpp/reconnect_backoff.dart';

void main() {
  test('CONNECT / DISCO / ping constants match Conversations Config', () {
    expect(connectTimeout, const Duration(seconds: 90));
    expect(connectDiscoTimeout, const Duration(seconds: 20));
    expect(pingMaxInterval, const Duration(seconds: 300));
    expect(pingMinInterval, const Duration(seconds: 30));
    expect(pingTimeout, const Duration(seconds: 15));
    expect(postConnectivityChangePingInterval, const Duration(seconds: 30));
  });
}
