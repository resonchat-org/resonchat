// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import 'package:resonchat/xmpp/muc_create.dart';

void main() {
  test('pronounceableRoomLocalpart is lowercase letters only', () {
    final s = pronounceableRoomLocalpart(Random(1));
    expect(s.length, inInclusiveRange(5, 11));
    expect(RegExp(r'^[a-z]+$').hasMatch(s), isTrue);
  });

  test('default group config is private and non-anonymous', () {
    final c = defaultGroupChatConfiguration(name: 'Team');
    expect(c['muc#roomconfig_membersonly'], isTrue);
    expect(c['muc#roomconfig_publicroom'], isFalse);
    expect(c['muc#roomconfig_whois'], 'anyone');
    expect(c['muc#roomconfig_roomname'], 'Team');
  });

  test('default channel config is public', () {
    final c = defaultChannelConfiguration();
    expect(c['muc#roomconfig_membersonly'], isFalse);
    expect(c['muc#roomconfig_publicroom'], isTrue);
    expect(c['muc#roomconfig_whois'], 'moderators');
    expect(c.containsKey('muc#roomconfig_roomname'), isFalse);
  });

  test('roomConfigFormValue encodes bools', () {
    expect(roomConfigFormValue(true), '1');
    expect(roomConfigFormValue(false), '0');
    expect(roomConfigFormValue('anyone'), 'anyone');
  });
}
