// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:test/test.dart';
import 'package:resonchat/xmpp/muc_detect.dart';

void main() {
  group('looksLikeChannelDomain', () {
    test('flags conference.* hosts like Conversations', () {
      expect(looksLikeChannelDomain('conference.example.org'), isTrue);
      expect(looksLikeChannelDomain('muc.example.org'), isTrue);
      expect(looksLikeChannelDomain('rooms.example.org'), isTrue);
    });

    test('ignores ordinary user domains', () {
      expect(looksLikeChannelDomain('example.org'), isFalse);
      expect(looksLikeChannelDomain('im.example.org'), isFalse);
    });
  });

  group('looksLikeChannelJid', () {
    test('reads the domain of a bare JID', () {
      expect(looksLikeChannelJid('news@conference.example.org'), isTrue);
      expect(looksLikeChannelJid('alice@example.org'), isFalse);
      expect(looksLikeChannelJid('not-a-jid'), isFalse);
    });
  });
}
