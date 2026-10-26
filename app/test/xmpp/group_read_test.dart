// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:test/test.dart';

import 'package:resonchat/xmpp/group_read.dart';
import 'package:resonchat/xmpp/muc/muc.dart';

Occupant member(String nick, String jid) => Occupant(
  nick: nick,
  affiliation: 'member',
  role: 'participant',
  realJid: jid,
);

void main() {
  test('split keeps members with a real JID and drops ourselves', () {
    final split = splitGroupReads(
      occupants: [
        member('me', 'me@example.org'),
        member('ada', 'Ada@Example.org'),
        member('bob', 'bob@example.org'),
        const Occupant(
          nick: 'anon',
          affiliation: 'member',
          role: 'participant',
        ),
        const Occupant(
          nick: 'guest',
          affiliation: 'none',
          role: 'visitor',
          realJid: 'guest@example.org',
        ),
      ],
      selfNick: 'me',
      selfBareJid: 'me@example.org',
      readJids: {'ada@example.org'},
    );
    expect(split.read.map((o) => o.nick), ['ada']);
    expect(split.unread.map((o) => o.nick), ['bob']);
    expect(
      groupReadFraction(
        occupants: [
          member('me', 'me@example.org'),
          member('ada', 'ada@example.org'),
          member('bob', 'bob@example.org'),
        ],
        selfNick: 'me',
        selfBareJid: 'me@example.org',
        readJids: {'ada@example.org'},
      ),
      0.5,
    );
  });

  test('read-by json round trips and ignores junk', () {
    expect(decodeReadBy(''), isEmpty);
    expect(decodeReadBy('not json'), isEmpty);
    expect(decodeReadBy(encodeReadBy({'b@x.org', 'a@x.org'})), {
      'a@x.org',
      'b@x.org',
    });
  });
}
