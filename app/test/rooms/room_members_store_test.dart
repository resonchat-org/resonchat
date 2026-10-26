// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moxxmpp/moxxmpp.dart';

import 'package:resonchat/persistence/database.dart';
import 'package:resonchat/xmpp/muc/muc.dart';

void main() {
  test('room member codec keeps the fields the read ring needs', () {
    final occupants = [
      Occupant(
        nick: 'alice',
        affiliation: 'member',
        role: 'participant',
        realJid: 'alice@example.com',
        show: PresenceShow.away,
      ),
      const Occupant(nick: 'bob', affiliation: 'owner', role: 'none'),
    ];
    final decoded = decodeRoomMembers(encodeRoomMembers(occupants));
    expect(decoded, occupants);
  });

  test('saved roster survives reopen and leaves with the chat', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    const room = 'room@muc.example';
    await db.saveRoomMembers(
      room,
      encodeRoomMembers(const [
        Occupant(
          nick: 'alice',
          affiliation: 'member',
          role: 'participant',
          realJid: 'alice@example.com',
        ),
      ]),
    );
    final blobs = await db.roomMemberBlobs();
    expect(blobs.keys, ['room@muc.example']);
    expect(decodeRoomMembers(blobs[room]!).single.realJid, 'alice@example.com');

    await db.upsertChat(room, isGroup: true, mucNick: 'me');
    await db.deleteChat(room);
    expect(await db.roomMemberBlobs(), isEmpty);
  });
}
