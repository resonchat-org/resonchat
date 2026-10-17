// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';

import 'package:test/test.dart';
import 'package:resonchat/net/socks5.dart';

void main() {
  group('SOCKS5 CONNECT request', () {
    test('domain name uses ATYP 0x03 (DNS at the proxy)', () {
      final req = buildSocks5ConnectRequest('example.org', 5222);
      expect(req[0], 0x05);
      expect(req[1], 0x01);
      expect(req[2], 0x00);
      expect(req[3], 0x03);
      expect(req[4], 'example.org'.length);
      expect(
        utf8.decode(req.sublist(5, 5 + 'example.org'.length)),
        'example.org',
      );
      expect(req[req.length - 2], 5222 >> 8);
      expect(req[req.length - 1], 5222 & 0xff);
    });

    test('IPv4 uses ATYP 0x01', () {
      final req = buildSocks5ConnectRequest('127.0.0.1', 9050);
      expect(req[3], 0x01);
      expect(req.sublist(4, 8), [127, 0, 0, 1]);
      expect(req[8], 9050 >> 8);
      expect(req[9], 9050 & 0xff);
    });
  });
}
