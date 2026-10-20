// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Who a group-chat message is encrypted *to*.
//
// The register below is restraint and refusal. Per function the question asked
// is "what is the worst thing that happens if this is wrong", and in this file
// that is always one of two outcomes: a room message leaves in the clear, or
// the sender is told a protection the message does not have. Both are silent.
// So the cases that matter are the ones where the module declines to decide,
// and the enumeration at the bottom exists to prove there is no input for
// which it decides wrongly instead.

import 'package:test/test.dart';

import 'package:resonchat/crypto/dual/track.dart';
import 'package:resonchat/crypto/dual/track_resolver.dart';
import 'package:resonchat/xmpp/muc.dart';
import 'package:resonchat/xmpp/muc_crypto.dart';

/// A fixed clock, so the staleness rule is tested rather than slept through.
final _now = DateTime.utc(2026, 5, 1, 12);

/// An occupant whose real JID the room publishes — the common case.
OccupantDevice dev(String nick, {bool reachable = true}) => OccupantDevice(
  nick: nick,
  realJid: '$nick@example.org',
  bundleReachable: reachable,
);

/// An occupant the room does not identify.
///
/// XEP-0045 permits this and plenty of rooms are configured that way, so it is
/// a state to be handled, not an error to be logged.
OccupantDevice anon(String nick, {bool reachable = true}) =>
    OccupantDevice(nick: nick, realJid: null, bundleReachable: reachable);

/// A snapshot read [age] before [_now].
OccupantSnapshot room(
  List<OccupantDevice> occupants, {
  bool complete = true,
  bool joined = true,
  Duration age = Duration.zero,
}) => OccupantSnapshot(
  occupants: occupants,
  readAt: _now.subtract(age),
  complete: complete,
  joined: joined,
);

TrackResolution send({
  required Track requested,
  required OccupantSnapshot snapshot,
  String? ourNick = 'me',
}) => resolveRoomSend(
  requested: requested,
  snapshot: snapshot,
  ourNick: ourNick,
  now: _now,
);

RoomUnreadable audience(OccupantSnapshot snapshot, {String? ourNick = 'me'}) =>
    unreadableOccupants(snapshot: snapshot, ourNick: ourNick, now: _now);

const alice = Occupant(nick: 'alice', affiliation: 'none', role: 'participant');
const quiet = Occupant(nick: 'quiet', affiliation: 'none', role: 'visitor');
const banned = Occupant(
  nick: 'banned',
  affiliation: 'outcast',
  role: 'participant',
);

PrivateRoomSend priv({
  required OccupantSnapshot snapshot,
  String roomJid = 'room@conference.example.org',
  String ourNick = 'me',
  String targetNick = 'alice',
  Occupant? target = alice,
  Track requested = Track.standard,
}) => resolvePrivateToOccupant(
  roomJid: roomJid,
  ourNick: ourNick,
  targetNick: targetNick,
  target: target,
  snapshot: snapshot,
  requested: requested,
  now: _now,
);

/// Every room state the rest of this file can describe, in one list.
final _rooms = <OccupantSnapshot>[
  room(const [], joined: false),
  room(const [], complete: false),
  room(const []),
  room([dev('me'), dev('alice')]),
  room([dev('me'), dev('alice')], complete: false),
  room([dev('me'), dev('alice')], joined: false),
  room([dev('me'), dev('alice')], age: const Duration(hours: 1)),
  room([dev('me'), anon('alice')]),
  room([dev('me'), dev('alice', reachable: false)]),
  room([anon('me'), anon('alice')]),
  room([dev('me'), dev('alice'), dev('bob', reachable: false)]),
];

void main() {
  group('a room we are not in', () {
    test('blocks, and says why', () {
      // Not in the room means there is no roster to decide against: the
      // service that owns it has not accepted our join. Reported as
      // unknownPeers rather than as a device problem, because telling the user
      // to fix somebody's devices when our own join is in flight sends them to
      // the wrong place.
      final r = send(
        requested: Track.standard,
        snapshot: room([dev('alice')], joined: false),
      );
      expect(r.canSend, isFalse);
      expect(r.blocked, TrackBlocked.unknownPeers);
      expect(r.track, Track.standard);
    });

    test('blocks even with a full roster of reachable occupants', () {
      // The roster is not consulted. A room we are not in delivers to nobody,
      // and a reachable bundle in it would be somebody we happen to have
      // looked up, not a recipient.
      final r = send(
        requested: Track.standard,
        snapshot: room([dev('me'), dev('alice')], joined: false),
      );
      expect(r.canSend, isFalse);
    });
  });

  group('a roster we could not fully read', () {
    test('blocks with the unknown-peers reason', () {
      // Exactly as an unreadable device list blocks for 1:1. Sending in the
      // clear because we could not read half the room's device list is the
      // worst outcome available in a room: the audience is a group, so the
      // message that escapes is the one that was said in front of people.
      final r = send(
        requested: Track.standard,
        snapshot: room([dev('me'), dev('alice')], complete: false),
      );
      expect(r.canSend, isFalse);
      expect(r.blocked, TrackBlocked.unknownPeers);
    });

    test('never yields plaintext', () {
      // The specific way that failure reaches the user: not "we could not
      // encrypt", but a message stored as sent and readable by the server.
      // `complete: false` with a reachable device in it is the dangerous
      // shape — anything keyed on "did we find anybody" would send, while the
      // other half of the room was never fetched.
      final r = send(
        requested: Track.standard,
        snapshot: room([dev('me'), dev('alice')], complete: false),
      );
      expect(r.track, isNot(Track.none));
    });

    test('a partial read of an empty room is not an empty room', () {
      // Two different answers that both have zero occupants in them: one is a
      // complete read that found nobody, the other is a read that did not
      // finish. Reporting the second as the first would tell the user to go and
      // turn encryption on for devices that were never looked up.
      final unreadable = send(
        requested: Track.standard,
        snapshot: room(const [], complete: false),
      );
      final empty = send(requested: Track.standard, snapshot: room(const []));
      expect(unreadable.blocked, TrackBlocked.unknownPeers);
      expect(empty.blocked, TrackBlocked.unreachableDevices);
    });
  });

  group('a roster that is too old', () {
    test('an hour old blocks with the unknown-peers reason', () {
      // Occupants move without notice. A list that is true of a room an hour
      // ago encrypts to somebody who has left and misses somebody who has
      // arrived, and the sentence we showed the sender before pressing send is
      // no longer true.
      final r = send(
        requested: Track.standard,
        snapshot: room([
          dev('me'),
          dev('alice'),
        ], age: const Duration(hours: 1)),
      );
      expect(r.canSend, isFalse);
      expect(r.blocked, TrackBlocked.unknownPeers);
    });

    test('the threshold is the age, not the age past it', () {
      // A boundary this exact is easy to get wrong in the permissive
      // direction by writing `>` where `>=` belongs, and then the rule does not
      // exist for any age that divides evenly.
      final justInside = send(
        requested: Track.standard,
        snapshot: room([
          dev('me'),
          dev('alice'),
        ], age: OccupantSnapshot.maxAge - const Duration(milliseconds: 1)),
      );
      final exactly = send(
        requested: Track.standard,
        snapshot: room([dev('me'), dev('alice')], age: OccupantSnapshot.maxAge),
      );
      expect(justInside.canSend, isTrue);
      expect(exactly.canSend, isFalse);
    });

    test('a snapshot dated in the future is not stale', () {
      // A clock disagreeing with the server's is not a room that changed.
      // Blocking on a condition we cannot detect would refuse sends for
      // reasons that are not real.
      final r = send(
        requested: Track.standard,
        snapshot: room([
          dev('me'),
          dev('alice'),
        ], age: const Duration(minutes: -30)),
      );
      expect(r.canSend, isTrue);
    });
  });

  group('the track a room message uses', () {
    test('post-quantum is allowed when the room roster is readable', () {
      // Affiliation members (incl. offline) are known for private non-anon
      // rooms; per-member PQ capability is checked at send time.
      final r = send(
        requested: Track.pq,
        snapshot: room([dev('me'), dev('alice')]),
      );
      expect(r.canSend, isTrue);
      expect(r.blocked, isNull);
      expect(r.track, Track.pq);
    });

    test('post-quantum still needs a joined readable room', () {
      final r = send(
        requested: Track.pq,
        snapshot: room([dev('me'), dev('alice')], joined: false),
      );
      expect(r.canSend, isFalse);
      expect(r.blocked, TrackBlocked.unknownPeers);
      expect(r.track, Track.pq);
    });

    test('post-quantum blocks on an incomplete roster like standard', () {
      final r = send(
        requested: Track.pq,
        snapshot: room([dev('me'), dev('alice')], complete: false),
      );
      expect(r.canSend, isFalse);
      expect(r.blocked, TrackBlocked.unknownPeers);
    });

    test('plaintext is honoured, because the user asked for it', () {
      // Same exception track_resolver.dart makes: refusing a choice the user
      // was warned about is the client overruling them. What makes this not a
      // silent downgrade is that the room send path confirms it first, which
      // is the UI's job and not something this module can check.
      for (var i = 0; i < _rooms.length; i++) {
        final r = send(requested: Track.none, snapshot: _rooms[i]);
        expect(r.canSend, isTrue, reason: 'snapshot #$i');
        expect(r.track, Track.none);
      }
    });

    test('standard sends on one reachable occupant device', () {
      // Weaker than the 1:1 rule on purpose: requiring every occupant's every
      // device would make any room containing one person with OMEMO switched
      // off permanently unsendable, which is most rooms.
      final r = send(
        requested: Track.standard,
        snapshot: room([dev('me'), dev('alice'), dev('bob', reachable: false)]),
      );
      expect(r.canSend, isTrue);
      expect(r.track, Track.standard);
    });

    test('an empty but reliable room blocks', () {
      // Read and found nobody. That is a real answer, and the answer is that
      // there is nobody to encrypt to — so it blocks rather than sending a
      // message the service will deliver to no one.
      final r = send(requested: Track.standard, snapshot: room(const []));
      expect(r.canSend, isFalse);
      expect(r.blocked, TrackBlocked.unreachableDevices);
    });

    test('a room containing only ourselves blocks', () {
      // The service delivers to everyone except the sender. Counting our own
      // reachable bundle would report a room of one as having a recipient, and
      // produce a bubble labelled OM that was addressed to nobody.
      final r = send(
        requested: Track.standard,
        snapshot: room([dev('me')]),
        ourNick: 'me',
      );
      expect(r.canSend, isFalse);
      expect(r.blocked, TrackBlocked.unreachableDevices);
    });

    test('an occupant with no published real JID is not reachable', () {
      // There is no address to put in a recipient list, so nothing can be
      // encrypted to them — not "not right now", but not at all. Treating it
      // as unknown-but-probably-fine is how a client promises a room-wide
      // guarantee about an occupant it has never been able to address.
      final r = send(
        requested: Track.standard,
        snapshot: room([dev('me'), anon('alice')]),
      );
      expect(r.canSend, isFalse);
      expect(r.blocked, TrackBlocked.unreachableDevices);
    });

    test(
      'a bundle that answered for an unpublished JID is still unreachable',
      () {
        // The constructor is allowed to hold this contradiction so a mapping
        // mistake upstream is visible instead of normalised away. The decision
        // must refuse it anyway.
        expect(
          const OccupantDevice(
            nick: 'alice',
            realJid: null,
            bundleReachable: true,
          ).isReachable,
          isFalse,
        );
        final r = send(
          requested: Track.standard,
          snapshot: room([
            dev('me'),
            const OccupantDevice(
              nick: 'alice',
              realJid: null,
              bundleReachable: true,
            ),
          ]),
        );
        expect(r.canSend, isFalse);
      },
    );
  });

  group('who cannot read it', () {
    test('is nobody when everyone is reachable', () {
      // The claim the UI makes before sending. If this is ever wrong the
      // sender is told the opposite of what will happen.
      final u = audience(room([dev('me'), dev('alice'), dev('bob')]));
      expect(u.occupants, isEmpty);
      expect(u.knowsEveryone, isTrue);
      expect(u.summary, contains('Everyone in the room'));
    });

    test('names the occupants whose bundle did not answer', () {
      final u = audience(
        room([dev('me'), dev('alice'), dev('bob', reachable: false)]),
      );
      expect(u.nicks, ['bob']);
      expect(u.knowsEveryone, isTrue);
      expect(u.summary, contains('bob'));
    });

    test('names an occupant with no published real JID', () {
      // They cannot read it, and the reason is not going to change by retrying.
      // Leaving them off this list would be a claim about somebody we have
      // never been able to address.
      final u = audience(room([dev('me'), dev('alice'), anon('bob')]));
      expect(u.nicks, ['bob']);
    });

    test('does not include us', () {
      // Without this the composer tells the sender they cannot read their own
      // message, in the room they are typing in.
      final u = audience(room([dev('me'), anon('me')]));
      expect(u.occupants, isEmpty);
      expect(u.knowsEveryone, isTrue);
    });

    test('counts people, not devices', () {
      // The sentence the composer shows is about people. Counting devices
      // would read "3 people in this room cannot read this" for one person
      // with three dead bundles.
      final u = audience(room([dev('me'), dev('bob', reachable: false)]));
      expect(u.count, 1);
      expect(u.summary, contains('1 person in this room'));
    });

    test('says two people cannot read this when two cannot', () {
      final u = audience(
        room([dev('me'), dev('bob', reachable: false), anon('carol')]),
      );
      expect(u.count, 2);
      expect(u.summary, contains('2 people in this room cannot read this'));
      expect(u.summary, contains('bob'));
      expect(u.summary, contains('carol'));
    });

    test(
      'knows nobody when the roster is partial, even with nobody on the list',
      () {
        // An incomplete read that found nobody unreadable has established that
        // we looked at part of the room. Saying "everyone can read this" would
        // be a room-wide guarantee from a roster that was never read.
        final u = audience(room([dev('me'), dev('alice')], complete: false));
        expect(u.occupants, isEmpty);
        expect(u.knowsEveryone, isFalse);
        expect(u.summary, contains('could not read the whole room'));
      },
    );

    test('knows nobody when we are not in the room', () {
      // The audience of a room we are not in is not the empty set; it is
      // unknown, and the empty set is what the UI would otherwise show.
      final u = audience(room([dev('alice')], joined: false));
      expect(u.knowsEveryone, isFalse);
    });

    test('still names what it did find when the roster is stale', () {
      // "At least these" is true even when the check was incomplete, so a
      // partial answer beats no answer.
      final u = audience(
        room([
          dev('me'),
          dev('bob', reachable: false),
          dev('alice'),
        ], age: const Duration(hours: 1)),
      );
      expect(u.nicks, ['bob']);
      expect(u.knowsEveryone, isFalse);
      expect(u.summary, contains('At least 1'));
    });
  });

  group('a private message to one occupant', () {
    test('is addressed room@server/ourNick/targetNick', () {
      // The two-resource form. Both nicknames are needed: ours to tell the
      // service who is sending, theirs to tell it who is receiving.
      final p = priv(snapshot: room([dev('me'), dev('alice')]));
      expect(p.canSend, isTrue);
      expect(p.address, 'room@conference.example.org/me/alice');
      // And the ciphertext is for the real JID, which is a different address
      // from the one the stanza goes to.
      expect(p.toJid, 'alice@example.org');
      expect(p.resolution.track, Track.standard);
    });

    test('a visitor cannot be addressed', () {
      // A server that let anyone message a visitor would be broadcasting to
      // somebody who explicitly asked not to be addressed. Asserted with a
      // perfectly reachable bundle on purpose: this refusal is about the room,
      // not about crypto, and a module that let it through whenever the crypto
      // looked good would be re-deriving the rule from the wrong input.
      final p = priv(
        snapshot: room([dev('me'), dev('quiet')]),
        targetNick: 'quiet',
        target: quiet,
      );
      expect(p.canSend, isFalse);
      expect(p.refusal, PrivateRefusal.notAddressable);
      expect(p.address, isNull);
      expect(p.resolution.canSend, isTrue);
    });

    test('an outcast cannot, even with a reachable bundle', () {
      // Being banned and then promoted is contradictory, and the ban wins:
      // we should not act on the more permissive half of an inconsistent
      // roster.
      final p = priv(
        snapshot: room([dev('me'), dev('banned')]),
        targetNick: 'banned',
        target: banned,
      );
      expect(p.canSend, isFalse);
      expect(p.refusal, PrivateRefusal.notAddressable);
    });

    test('a nickname nobody holds is not present', () {
      final p = priv(snapshot: room([dev('me'), dev('bob')]), target: null);
      expect(p.canSend, isFalse);
      expect(p.refusal, PrivateRefusal.notPresent);
      expect(p.address, isNull);
    });

    test('a stale roster refuses, because a nickname is not an identity', () {
      // The room-shaped path has no equivalent of this: the service resolves
      // the nickname at delivery, so a roster an hour old can put a message
      // encrypted to A in front of B, and the ciphertext would be the one
      // thing protecting it.
      final p = priv(
        snapshot: room([
          dev('me'),
          dev('alice'),
        ], age: const Duration(hours: 1)),
      );
      expect(p.canSend, isFalse);
      expect(p.refusal, PrivateRefusal.audienceUnknown);
      expect(p.resolution.blocked, TrackBlocked.unknownPeers);
    });

    test('refuses while the join is still in flight', () {
      final p = priv(snapshot: room([dev('me'), dev('alice')], joined: false));
      expect(p.canSend, isFalse);
      expect(p.refusal, PrivateRefusal.audienceUnknown);
    });

    test('an occupant whose bundle did not answer blocks', () {
      // The audience is one person again, so the 1:1 rule applies: *this*
      // person must be reachable. A reachability rule relaxed for a room would
      // be a rule that quietly survived the narrowing.
      final p = priv(
        snapshot: room([dev('me'), dev('alice', reachable: false)]),
      );
      expect(p.canSend, isFalse);
      expect(p.resolution.blocked, TrackBlocked.unreachableDevices);
    });

    test('an occupant with no published real JID blocks', () {
      final p = priv(snapshot: room([dev('me'), anon('alice')]));
      expect(p.canSend, isFalse);
      expect(p.resolution.blocked, TrackBlocked.unreachableDevices);
      expect(p.toJid, isNull);
    });

    test('a roster that names them but whose devices were never mapped is unknown', () {
      // A mapping gap is not a positive finding of "this person has no
      // devices", so it must not be reported as one — that would tell the user
      // to go and fix a device that may be perfectly fine.
      final p = priv(snapshot: room([dev('me'), dev('bob')]));
      expect(p.canSend, isFalse);
      expect(p.resolution.blocked, TrackBlocked.unknownPeers);
    });

    test('post-quantum private PM is allowed when the occupant is known', () {
      final p = priv(
        snapshot: room([dev('me'), dev('alice')]),
        requested: Track.pq,
      );
      expect(p.canSend, isTrue);
      expect(p.resolution.blocked, isNull);
      expect(p.resolution.track, Track.pq);
      expect(p.address, isNotNull);
    });

    test('a room JID that is not bare is refused as malformed', () {
      // The single most common MUC mistake, and it fails silently: the service
      // accepts the stanza and delivers it to nobody, so the sender sees a
      // bubble that looks sent.
      final p = priv(
        snapshot: room([dev('me'), dev('alice')]),
        roomJid: 'room@conference.example.org/me',
      );
      expect(p.canSend, isFalse);
      expect(p.refusal, PrivateRefusal.malformedAddress);
      expect(p.address, isNull);
    });

    test('a nickname containing a slash cannot be addressed', () {
      // muc.dart keeps such a nickname in the roster rather than truncating
      // it, but `room/nick/occupant` has no way to express one, so the
      // address we would build names somebody else or nobody.
      final p = priv(
        snapshot: room([dev('me'), dev('a/b')]),
        targetNick: 'a/b',
        target: const Occupant(
          nick: 'a/b',
          affiliation: 'none',
          role: 'participant',
        ),
      );
      expect(p.canSend, isFalse);
      expect(p.refusal, PrivateRefusal.malformedAddress);
    });

    test('every refusal leaves no address behind to send to', () {
      // The address is withheld rather than returned for the caller to use
      // anyway: handing out the address of a message we just refused is how
      // "this person asked not to be addressed" gets overridden by a caller
      // that read the wrong field.
      for (final p in [
        priv(
          snapshot: room([dev('me'), dev('quiet')]),
          targetNick: 'quiet',
          target: quiet,
        ),
        priv(snapshot: room([dev('me'), dev('bob')]), target: null),
        priv(snapshot: room([dev('me'), dev('alice')], joined: false)),
        priv(snapshot: room([dev('me'), dev('alice')], complete: false)),
        priv(snapshot: room([dev('me'), dev('alice')]), roomJid: 'room/me'),
      ]) {
        expect(p.canSend, isFalse, reason: '${p.refusal}');
        expect(p.address, isNull, reason: '${p.refusal}');
        expect(p.toJid, isNull, reason: '${p.refusal}');
      }
    });
  });

  group('the invariant this file exists for', () {
    test('no encrypted request comes back as plaintext', () {
      // The important assertion. Every case above is a specific refusal; this
      // one says there is no input at all that turns an encryption request
      // into Track.none. If one appears, a room message leaves in the clear
      // with no dialog, no warning, and nothing stored saying so.
      //
      // Track.none is excluded from the enumeration on purpose: it is not a
      // silent outcome, it is a request, and the room send path confirms it
      // with the user before calling here. Including it would test that
      // confirmation, which lives in the UI.
      final seen = <TrackResolution>[
        for (final requested in [Track.standard, Track.pq])
          for (final snapshot in _rooms)
            send(requested: requested, snapshot: snapshot),
      ];
      expect(seen, isNotEmpty);
      for (final r in seen) {
        expect(
          r.track == Track.none && r.blocked == null,
          isFalse,
          reason: '$r must not be silently plaintext',
        );
      }
    });

    test('the track reported is always the one requested', () {
      // Not "close enough", not "safe": the one asked for, or nothing is sent.
      // A resolution that answered a blocked request with a working track
      // would make the refusal dialog undecidable and the bubble label a lie.
      for (final requested in Track.values) {
        for (var i = 0; i < _rooms.length; i++) {
          final r = send(requested: requested, snapshot: _rooms[i]);
          expect(r.track, requested, reason: '$requested on snapshot #$i');
        }
      }
    });

    test('can send only when the room is one we vouch for right now', () {
      // The strongest claim a send here makes is "these people can read it".
      // It may only be made against a snapshot that describes the room as it
      // is, and only when there is somebody other than us to send to.
      for (var i = 0; i < _rooms.length; i++) {
        final snapshot = _rooms[i];
        final r = send(requested: Track.standard, snapshot: snapshot);
        if (!r.canSend) continue;
        expect(
          audience(snapshot).knowsEveryone,
          isTrue,
          reason: 'snapshot #$i',
        );
        expect(
          snapshot.occupants.any((o) => o.nick != 'me' && o.isReachable),
          isTrue,
          reason: 'snapshot #$i',
        );
      }
    });

    test('a blocked resolution never offers plaintext as the alternative', () {
      // "Send it in the clear" as the remedy for "we could not read the room"
      // turns a transient network problem into a downgrade the user confirms
      // under pressure.
      for (final requested in [Track.standard, Track.pq]) {
        for (var i = 0; i < _rooms.length; i++) {
          final r = send(requested: requested, snapshot: _rooms[i]);
          if (r.canSend) continue;
          expect(r.alternative, isNotNull, reason: '$r');
          expect(r.alternative, isNot(Track.none), reason: '$r');
        }
      }
    });

    test('no room state reports a room-wide guarantee it cannot back', () {
      // knowsEveryone is the whole difference between "everyone can read
      // this" and "we looked at part of the room". Every state this module
      // cannot vouch for has to say so, including the ones where the
      // unreadable list happens to be empty.
      for (var i = 0; i < _rooms.length; i++) {
        final snapshot = _rooms[i];
        final known =
            snapshot.joined && snapshot.complete && !snapshot.isStale(_now);
        expect(audience(snapshot).knowsEveryone, known, reason: 'snapshot #$i');
      }
    });
  });
}
