// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:moxxmpp/moxxmpp.dart' show JID, StanzaId;
import 'package:test/test.dart';

import 'package:resonchat/xmpp/stanza_id.dart';

void main() {
  const room = 'room@conference.example';

  test('account archive groupchat is not the room archive', () {
    expect(
      groupchatOnAccountArchive(archiveBare: 'me@example.org', roomBare: room),
      isTrue,
    );
    expect(
      groupchatOnAccountArchive(archiveBare: room, roomBare: room),
      isFalse,
    );
  });

  test('a MUC archive result id is the room stanza id', () {
    expect(
      roomServerMessageId(
        mucArchive: true,
        archiveResultId: 'result-1',
        trustStanzaId: false,
        stanzaIds: [StanzaId('spoofed', JID.fromString(room))],
        roomBare: room,
      ),
      'result-1',
    );
  });

  test('a live stanza-id counts only when the room advertises it', () {
    final ids = [StanzaId('live-1', JID.fromString(room))];
    expect(
      roomServerMessageId(
        mucArchive: false,
        archiveResultId: null,
        trustStanzaId: false,
        stanzaIds: ids,
        roomBare: room,
      ),
      isNull,
    );
    expect(
      roomServerMessageId(
        mucArchive: false,
        archiveResultId: null,
        trustStanzaId: true,
        stanzaIds: ids,
        roomBare: room,
      ),
      'live-1',
    );
    expect(
      roomServerMessageId(
        mucArchive: false,
        archiveResultId: null,
        trustStanzaId: true,
        stanzaIds: [
          StanzaId('nope', JID.fromString('other@conference.example')),
        ],
        roomBare: room,
      ),
      isNull,
    );
  });
}
