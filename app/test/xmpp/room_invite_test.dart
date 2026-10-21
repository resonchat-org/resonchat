// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:moxxmpp/moxxmpp.dart';
import 'package:test/test.dart';

import 'package:resonchat/xmpp/muc/room_invite.dart';

void main() {
  test('parses a mediated muc#user invite', () {
    final stanza = Stanza.message(
      from: 'room@conference.example.org',
      to: 'me@example.org',
      children: [
        XMLNode.xmlns(
          tag: 'x',
          xmlns: mucUserXmlns,
          children: [
            XMLNode(
              tag: 'invite',
              attributes: {'from': 'alice@example.org/phone'},
              children: [XMLNode(tag: 'reason', text: 'join us')],
            ),
            XMLNode(tag: 'password', text: 's3cret'),
          ],
        ),
      ],
    );
    final invite = parseRoomInvite(stanza)!;
    expect(invite.roomJid, 'room@conference.example.org');
    expect(invite.fromJid, 'alice@example.org');
    expect(invite.reason, 'join us');
    expect(invite.password, 's3cret');
  });

  test('parses a direct jabber:x:conference invite', () {
    final stanza = Stanza.message(
      from: 'bob@example.org/laptop',
      to: 'me@example.org',
      children: [
        XMLNode.xmlns(
          tag: 'x',
          xmlns: 'jabber:x:conference',
          attributes: {
            'jid': 'party@muc.example.org',
            'password': 'pw',
            'reason': 'party',
          },
        ),
      ],
    );
    final invite = parseRoomInvite(stanza)!;
    expect(invite.roomJid, 'party@muc.example.org');
    expect(invite.fromJid, 'bob@example.org');
    expect(invite.password, 'pw');
    expect(invite.reason, 'party');
  });

  test('ignores ordinary chat messages', () {
    final stanza = Stanza.message(
      from: 'alice@example.org',
      children: [XMLNode(tag: 'body', text: 'hi')],
    );
    expect(parseRoomInvite(stanza), isNull);
  });
}
