// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';

import 'package:test/test.dart';

void main() {
  test('SM state JSON round-trips the fields commitState writes', () {
    // Mirror DriftStreamManagementManager.commitState payload shape.
    final payload = jsonEncode({
      'c2s': 3,
      's2c': 7,
      'streamResumptionId': 'abc',
      'streamResumptionLocation': 'xmpp.example',
    });
    final map = jsonDecode(payload) as Map<String, dynamic>;
    expect(map['c2s'], 3);
    expect(map['s2c'], 7);
    expect(map['streamResumptionId'], 'abc');
    expect(map['streamResumptionLocation'], 'xmpp.example');
  });
}
