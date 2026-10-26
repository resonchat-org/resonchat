// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Group chats (XEP-0045).
//
// Most of these are about addresses, because in XEP-0045 almost every mistake
// is an address mistake — and every one of them fails silently. A message sent
// to a bare room is accepted by the server and delivered to nobody; a room and
// one of its occupants stored as two conversations shows half the messages in
// one and half in the other.

import 'package:moxxmpp/moxxmpp.dart';
import 'package:test/test.dart';

import 'package:resonchat/crypto/dual/track.dart';
import 'package:resonchat/crypto/dual/track_resolver.dart';
import 'package:resonchat/xmpp/muc/muc.dart';

void main() {
  group('private non-anonymous (Conversations)', () {
    test('both muc_membersonly and muc_nonanonymous are required', () {
      expect(
        isPrivateAndNonAnonymous(['muc_membersonly', 'muc_nonanonymous']),
        isTrue,
      );
      expect(isPrivateAndNonAnonymous(['muc_membersonly']), isFalse);
      expect(isPrivateAndNonAnonymous(['muc_nonanonymous']), isFalse);
      expect(isPrivateAndNonAnonymous([]), isFalse);
    });

    test('crypto targets are member real JIDs, excluding ourselves', () {
      final targets = mucCryptoTargets(
        ourBareJid: 'me@example.org',
        occupants: const [
          Occupant(
            nick: 'me',
            affiliation: 'member',
            role: 'participant',
            realJid: 'me@example.org',
          ),
          Occupant(
            nick: 'alice',
            affiliation: 'member',
            role: 'participant',
            realJid: 'alice@example.org',
          ),
          Occupant(
            nick: 'visitor',
            affiliation: 'none',
            role: 'visitor',
            realJid: 'v@example.org',
          ),
          Occupant(nick: 'anon', affiliation: 'member', role: 'participant'),
        ],
      );
      expect(targets, ['alice@example.org']);
    });

    test('jid-visible display includes offline affiliation members', () {
      // Non-anon or privileged (admin): affiliation stubs + online presence.
      const offline = Occupant(
        nick: 'bob',
        affiliation: 'member',
        role: 'none',
        realJid: 'bob@example.org',
      );
      const online = Occupant(
        nick: 'alice',
        affiliation: 'member',
        role: 'participant',
        realJid: 'alice@example.org',
      );
      final display = roomMembersForDisplay(
        includeOfflineAffiliates: true,
        affiliation: const [offline, online],
        online: const [online],
      );
      expect(display.map((o) => o.realJid).toSet(), {
        'bob@example.org',
        'alice@example.org',
      });
      final targets = mucCryptoTargets(
        occupants: display,
        ourBareJid: 'me@example.org',
      );
      expect(targets.toSet(), {'bob@example.org', 'alice@example.org'});
    });

    test('without jid visibility display only online occupants', () {
      const offline = Occupant(
        nick: 'bob',
        affiliation: 'member',
        role: 'none',
        realJid: 'bob@example.org',
      );
      const online = Occupant(
        nick: 'alice',
        affiliation: 'none',
        role: 'participant',
        realJid: 'alice@example.org',
      );
      final display = roomMembersForDisplay(
        includeOfflineAffiliates: false,
        affiliation: const [offline],
        online: const [online],
      );
      expect(display, [online]);
    });

    test('resolveRoomRoster keeps saved when live is empty', () {
      const saved = Occupant(
        nick: 'bob',
        affiliation: 'member',
        role: 'none',
        realJid: 'bob@example.org',
      );
      expect(resolveRoomRoster(live: const [], saved: const [saved]), [saved]);
    });

    test('resolveRoomRoster keeps saved JIDs over nick-only live', () {
      const saved = Occupant(
        nick: 'bob',
        affiliation: 'member',
        role: 'none',
        realJid: 'bob@example.org',
      );
      const liveNickOnly = Occupant(
        nick: 'bob',
        affiliation: 'none',
        role: 'participant',
      );
      expect(
        resolveRoomRoster(live: const [liveNickOnly], saved: const [saved]),
        [saved],
      );
      expect(
        shouldPersistRoomRoster(
          live: const [liveNickOnly],
          saved: const [saved],
        ),
        isFalse,
      );
    });

    test('resolveRoomRoster takes live when it has real JIDs', () {
      const saved = Occupant(
        nick: 'bob',
        affiliation: 'member',
        role: 'none',
        realJid: 'bob@example.org',
      );
      const live = Occupant(
        nick: 'bob',
        affiliation: 'member',
        role: 'participant',
        realJid: 'bob@example.org',
      );
      expect(resolveRoomRoster(live: const [live], saved: const [saved]), [
        live,
      ]);
      expect(
        shouldPersistRoomRoster(live: const [live], saved: const [saved]),
        isTrue,
      );
    });

    test('canSeeRoomMemberJids: non-anon or owner/admin', () {
      expect(
        canSeeRoomMemberJids(nonAnonymous: true, selfAffiliation: 'none'),
        isTrue,
      );
      expect(
        canSeeRoomMemberJids(nonAnonymous: false, selfAffiliation: 'admin'),
        isTrue,
      );
      expect(
        canSeeRoomMemberJids(nonAnonymous: false, selfAffiliation: 'owner'),
        isTrue,
      );
      expect(
        canSeeRoomMemberJids(nonAnonymous: false, selfAffiliation: 'member'),
        isFalse,
      );
    });

    test('online presence overlays affiliation stub for the same real JID', () {
      const stub = Occupant(
        nick: 'alice',
        affiliation: 'member',
        role: 'none',
        realJid: 'alice@example.org',
      );
      const live = Occupant(
        nick: 'AliceNick',
        affiliation: 'member',
        role: 'moderator',
        realJid: 'alice@example.org',
      );
      final merged = mergeRoomMembers(
        affiliation: const [stub],
        online: const [live],
      );
      expect(merged, [live]);
    });

    test('muc#admin item parses to an offline member stub', () {
      final item = XMLNode(
        tag: 'item',
        attributes: {
          'affiliation': 'member',
          'jid': 'bob@example.org/phone',
          'nick': 'Bob',
        },
      );
      final o = occupantFromAdminItem(item);
      expect(o?.realJid, 'bob@example.org');
      expect(o?.nick, 'Bob');
      expect(o?.affiliation, 'member');
      expect(o?.role, 'none');
      expect(o?.isOnline, isFalse);
    });
  });

  group('Gajim moderation gates', () {
    test('role change requires moderator and affiliation rank', () {
      const visitor = Occupant(nick: 'v', affiliation: 'none', role: 'visitor');
      expect(
        canChangeOccupantRole(
          selfRole: 'participant',
          selfAffiliation: 'owner',
          target: visitor,
        ),
        isFalse,
      );
      expect(
        canChangeOccupantRole(
          selfRole: 'moderator',
          selfAffiliation: 'member',
          target: visitor,
        ),
        isTrue,
      );
      expect(
        canChangeOccupantRole(
          selfRole: 'moderator',
          selfAffiliation: 'member',
          target: const Occupant(
            nick: 'a',
            affiliation: 'admin',
            role: 'moderator',
          ),
        ),
        isFalse,
      );
    });

    test('affiliation change: admin cannot promote to admin/owner', () {
      const member = Occupant(
        nick: 'm',
        affiliation: 'member',
        role: 'participant',
      );
      expect(
        canChangeOccupantAffiliation(
          selfAffiliation: 'admin',
          target: member,
          toAffiliation: 'owner',
        ),
        isFalse,
      );
      expect(
        canChangeOccupantAffiliation(
          selfAffiliation: 'admin',
          target: member,
          toAffiliation: 'none',
        ),
        isTrue,
      );
      expect(
        canChangeOccupantAffiliation(
          selfAffiliation: 'owner',
          target: member,
          toAffiliation: 'admin',
        ),
        isTrue,
      );
      expect(
        canChangeOccupantAffiliation(
          selfAffiliation: 'owner',
          target: member,
          toAffiliation: 'member',
        ),
        isFalse,
      );
    });
  });

  group('Gajim roster groups', () {
    test('owner/admin by affiliation; others by role', () {
      expect(
        mucRosterGroupKey(
          const Occupant(nick: 'o', affiliation: 'owner', role: 'moderator'),
        ),
        'owner',
      );
      expect(
        mucRosterGroupKey(
          const Occupant(nick: 'a', affiliation: 'admin', role: 'moderator'),
        ),
        'admin',
      );
      expect(
        mucRosterGroupKey(
          const Occupant(nick: 'm', affiliation: 'member', role: 'moderator'),
        ),
        'moderator',
      );
      expect(
        mucRosterGroupKey(
          const Occupant(nick: 'p', affiliation: 'member', role: 'participant'),
        ),
        'participant',
      );
      expect(
        mucRosterGroupKey(
          const Occupant(nick: 'v', affiliation: 'none', role: 'visitor'),
        ),
        'visitor',
      );
      // Offline affiliation stubs (role=none) sit with participants.
      expect(
        mucRosterGroupKey(
          const Occupant(nick: 'offline', affiliation: 'member', role: 'none'),
        ),
        'participant',
      );
    });

    test('groupOccupantsForRoster preserves Gajim section order', () {
      final grouped = groupOccupantsForRoster(const [
        Occupant(nick: 'visit', affiliation: 'none', role: 'visitor'),
        Occupant(nick: 'own', affiliation: 'owner', role: 'moderator'),
        Occupant(nick: 'part', affiliation: 'member', role: 'participant'),
        Occupant(nick: 'adm', affiliation: 'admin', role: 'moderator'),
        Occupant(nick: 'mod', affiliation: 'member', role: 'moderator'),
      ]);
      expect(grouped.keys.toList(), [
        'owner',
        'admin',
        'moderator',
        'participant',
        'visitor',
      ]);
      expect(grouped['owner']!.single.nick, 'own');
      expect(grouped['admin']!.single.nick, 'adm');
      expect(grouped['moderator']!.single.nick, 'mod');
      expect(grouped['participant']!.single.nick, 'part');
      expect(grouped['visitor']!.single.nick, 'visit');
    });
  });

  group('addresses', () {
    test(
      'presence and PMs use room@server/nick; groupchat uses the bare room',
      () {
        // Join presence is full JID; group messages are type=groupchat to bare
        // (XEP-0045 / Conversations). myAddress is the occupant address only.
        const chat = GroupChat(
          roomJid: 'room@conference.example.org',
          nick: 'me',
          occupants: [],
        );
        expect(chat.myAddress, 'room@conference.example.org/me');
        expect(chat.roomJid, 'room@conference.example.org');
      },
    );

    test('the room JID and the occupant address are the same conversation', () {
      expect(GroupChat.parseAddress('room@conference.example.org/me'), (
        roomJid: 'room@conference.example.org',
        nick: 'me',
      ));
    });

    test('a bare JID is not a room', () {
      // A 1:1 conversation and a room live in the same table. Confusing them
      // means sending a room's messages to a person.
      expect(GroupChat.parseAddress('peer@example.org'), isNull);
      expect(GroupChat.isRoomAddress('peer@example.org'), isFalse);
      expect(GroupChat.isRoomAddress('room@conference.example.org/me'), isTrue);
    });

    test('an empty nick is not a room either', () {
      expect(GroupChat.parseAddress('room@conference.example.org/'), isNull);
    });

    test('a nickname containing a slash survives', () {
      // Some clients allow it; truncating at the second slash would put the
      // message in a conversation that does not exist.
      expect(GroupChat.parseAddress('room@conference.example.org/a/b'), (
        roomJid: 'room@conference.example.org',
        nick: 'a/b',
      ));
    });
  });

  group('occupants', () {
    test('a visitor cannot be addressed', () {
      // A server that let anyone message a visitor would be broadcasting to
      // somebody who explicitly asked not to be addressed.
      const visitor = Occupant(
        nick: 'quiet',
        affiliation: 'none',
        role: 'visitor',
      );
      expect(visitor.canSpeak, isFalse);
      expect(visitor.isAddressable, isFalse);
    });

    test('a participant can', () {
      const participant = Occupant(
        nick: 'here',
        affiliation: 'none',
        role: 'participant',
      );
      expect(participant.canSpeak, isTrue);
      expect(participant.isAddressable, isTrue);
    });

    test('an outcast cannot, even if the server gave them a role', () {
      // Being banned and then promoted are contradictory, and the ban is the
      // one that must win: a server that reports both is telling us its own
      // state is inconsistent, and we should not act on the more permissive
      // half.
      const banned = Occupant(
        nick: 'banned',
        affiliation: 'outcast',
        role: 'participant',
      );
      expect(banned.isAddressable, isFalse);
    });

    test('an owner who is only a participant is not a moderator now', () {
      // Ownership is what the room's configuration says; the role is what they
      // may do this minute. An owner demoted to participant cannot change the
      // configuration until promoted back.
      const owner = Occupant(
        nick: 'owner',
        affiliation: 'owner',
        role: 'participant',
      );
      expect(owner.isModerator, isFalse);
      expect(owner.canSpeak, isTrue);
    });
  });

  group('which track a room uses', () {
    test('post-quantum is not offered for rooms', () {
      // A room's recipient set is "whoever is in it right now", and that
      // cannot be established at the moment a message is sent. Offering PQ here
      // would be offering a track we cannot decide on.
      final r = resolveRoomTrack(
        occupantOmemoDevices: {1, 2, 3},
        devicesReadable: true,
      );
      expect(r.track, Track.standard);
      expect(r.canSend, isTrue);
    });

    test('an unreadable device list blocks, like a 1:1 conversation', () {
      // Silently sending a room message in the clear because the occupant
      // list was momentarily unreadable would be the worst outcome for a room,
      // where the audience is a group.
      final r = resolveRoomTrack(
        occupantOmemoDevices: const {},
        devicesReadable: false,
      );
      expect(r.canSend, isFalse);
      expect(r.blocked, TrackBlocked.unknownPeers);
    });

    test('no reachable occupant device blocks', () {
      final r = resolveRoomTrack(
        occupantOmemoDevices: const {},
        devicesReadable: true,
      );
      expect(r.canSend, isFalse);
      expect(r.blocked, TrackBlocked.unreachableDevices);
    });

    test('one reachable device is enough, unlike a 1:1 conversation', () {
      // Requiring every occupant's every device would be unreachable in any
      // room containing somebody who has OMEMO turned off — which is most
      // rooms. A room's guarantee is "the people who can read it can read it".
      final r = resolveRoomTrack(
        occupantOmemoDevices: {7},
        devicesReadable: true,
      );
      expect(r.canSend, isTrue);
    });
  });

  group('occupant changes', () {
    const a = Occupant(nick: 'a', affiliation: 'none', role: 'participant');
    const b = Occupant(nick: 'b', affiliation: 'none', role: 'participant');
    const mod = Occupant(nick: 'b', affiliation: 'admin', role: 'moderator');

    test('a new arrival is reported as joined', () {
      final changes = diffOccupants(const [], [a, b]);
      expect(
        changes.where((c) => c.change == OccupantChange.joined),
        hasLength(2),
      );
    });

    test('a departure is reported against the person who left', () {
      final changes = diffOccupants([a, b], [a]);
      final left = changes.singleWhere((c) => c.change == OccupantChange.left);
      expect(left.occupant.nick, 'b');
      expect(left.previousNick, 'b');
    });

    test('a promotion is called out, not just "changed"', () {
      final changes = diffOccupants([a, b], [a, mod]);
      expect(changes.any((c) => c.change == OccupantChange.promoted), isTrue);
    });

    test('a demotion is called out', () {
      final changes = diffOccupants([a, mod], [a, b]);
      expect(changes.any((c) => c.change == OccupantChange.demoted), isTrue);
    });

    test('an unchanged roster produces nothing', () {
      // A room of thirty people produces a presence storm on every reconnect;
      // a log of all of it is unreadable, and the user cares about who is new
      // and who left.
      expect(diffOccupants([a, b], [a, b]), isEmpty);
    });

    test('an empty room produces a departure for everyone', () {
      final changes = diffOccupants([a, b], const []);
      expect(
        changes.where((c) => c.change == OccupantChange.left),
        hasLength(2),
      );
    });
  });
}
