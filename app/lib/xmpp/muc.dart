// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Group chats (XEP-0045).
//
// A room is addressed as `room@server/nick`, and almost every decision here
// follows from that one fact:
//
//   * Outgoing messages go to `room@server/ourNick`, not to the bare room. A
//     message addressed to the room goes to nobody in particular and many
//     servers drop it.
//   * The sender of an incoming message is the *nick*, not the room. Showing
//     `room@server/nick` in a bubble makes the room unreadable, and the bare
//     room says nothing about who spoke.
//   * Occupants change without notice. Anything computed once at join time — a
//     device list, a track decision — is stale by the time it is used, so
//     nothing here is cached beyond what the presence stream itself says.
//
// On encryption, the honest position: a room's recipient set is "whoever is in
// it right now", and that set cannot be established at the moment a message is
// sent. So the post-quantum track is **not offered** for rooms. Standard OMEMO
// is, addressed at the occupants' published devices — and when that cannot be
// established, the room falls back to the same refuse-and-explain path a 1:1
// conversation uses. Silently sending a room message in the clear because the
// occupant list was momentarily unreadable would be the worst possible outcome
// for a room, where the audience is a group.

import 'package:moxxmpp/moxxmpp.dart';

import '../omemo/track.dart';
import '../omemo/track_resolver.dart';

/// A MUC service that did not answer a join at all.
///
/// Not one of moxxmpp's error types, on purpose: "the service did not reply" and
/// "the service refused" are different things, and the user needs to be told
/// which happened. Collapsing them into one "could not join" is what makes a
/// mistyped room address indistinguishable from a ban.
class MucServiceUnresponsive implements MUCError {
  const MucServiceUnresponsive(this.roomJid);

  final String roomJid;

  @override
  String toString() =>
      'no response from the service hosting $roomJid (wrong address, or the '
      'service is not a group-chat service)';
}

/// One person in a room.
class Occupant {
  const Occupant({
    required this.nick,
    required this.affiliation,
    required this.role,
  });

  /// The room-local nickname. Stable for as long as they are in the room, and
  /// the only thing a message from them can be attributed to.
  final String nick;

  /// 'owner', 'admin', 'member', 'none' or 'outcast'.
  final String affiliation;

  /// 'moderator', 'participant', 'visitor' or 'none'.
  ///
  /// What the user may do *now*: an owner who is only a participant cannot
  /// change the room's configuration until the server promotes them back.
  final String role;

  bool get isModerator => role == 'moderator';
  bool get canSpeak => role == 'moderator' || role == 'participant';

  /// Whether this occupant may be addressed by others in the room.
  ///
  /// Visitors cannot: a server that let anyone message a visitor would be
  /// broadcasting to somebody who explicitly asked not to be addressed.
  bool get isAddressable => canSpeak && affiliation != 'outcast';

  factory Occupant.from(RoomMember member) => Occupant(
        nick: member.nick,
        affiliation: member.affiliation.value,
        role: member.role.value,
      );

  @override
  bool operator ==(Object other) =>
      other is Occupant &&
      other.nick == nick &&
      other.affiliation == affiliation &&
      other.role == role;

  @override
  int get hashCode => Object.hash(nick, affiliation, role);
}

/// A room we are in.
class GroupChat {
  const GroupChat({
    required this.roomJid,
    required this.nick,
    required this.occupants,
    this.subject,
    this.joined = false,
  });

  /// The bare room JID, `room@server`.
  final String roomJid;

  /// Our nickname in this room.
  final String nick;

  /// Everyone currently in the room, in the order the server listed them.
  final List<Occupant> occupants;

  final String? subject;

  final bool joined;

  /// Where our messages go.
  ///
  /// `room@server/ourNick` — not the bare room. This is the single most common
  /// MUC mistake and it fails silently: the server accepts the stanza and
  /// delivers it to nobody.
  String get myAddress => '${roomJid.isEmpty ? '' : '$roomJid/'}$nick';

  bool get isMuc => true;

  /// The occupant whose nickname is [nick], or null.
  Occupant? occupant(String nick) {
    for (final o in occupants) {
      if (o.nick == nick) return o;
    }
    return null;
  }

  GroupChat copyWith({
    List<Occupant>? occupants,
    String? subject,
    bool? joined,
  }) {
    return GroupChat(
      roomJid: roomJid,
      nick: nick,
      occupants: occupants ?? this.occupants,
      subject: subject ?? this.subject,
      joined: joined ?? this.joined,
    );
  }

  /// Parses `room@server` and `room@server/nick`.
  ///
  /// Returns null for a bare JID, because a 1:1 conversation and a room are
  /// stored in the same table and confusing them would send a room's messages
  /// to a person.
  static ({String roomJid, String nick})? parseAddress(String jid) {
    final parts = jid.split('/');
    if (parts.length < 2 || parts[1].isEmpty) return null;
    return (roomJid: parts[0], nick: parts.sublist(1).join('/'));
  }

  /// True when [jid] addresses a room rather than a person.
  ///
  /// Structural, and that is the point: a room is the only kind of address
  /// whose resource part is *our* nickname rather than the sender's.
  static bool isRoomAddress(String jid) {
    final parsed = parseAddress(jid);
    if (parsed == null) return false;
    // A service that looks like a room is more common than it sounds: several
    // servers use a resource for gateway and moderation contacts. Rooms are
    // distinguished by the muc service actually offering XEP-0045, which is
    // checked separately — so this is the cheap test, not the whole one.
    return parsed.roomJid.contains('@');
  }
}

/// Which track a room message goes out on.
///
/// Rooms get their own resolver rather than reusing the 1:1 one because the
/// question is genuinely different. A 1:1 conversation has a fixed recipient
/// set we can enumerate; a room does not, so the standard track is available
/// whenever we have *any* reachable occupant device, rather than requiring every
/// device of every occupant — which would be unreachable in a room with anyone
/// who has OMEMO disabled.
TrackResolution resolveRoomTrack({
  required Set<int> occupantOmemoDevices,
  required bool devicesReadable,
}) {
  if (!devicesReadable) {
    // Same reasoning as a 1:1 conversation: not knowing is not permission.
    return const TrackResolution(
      track: Track.standard,
      blocked: TrackBlocked.unknownPeers,
    );
  }
  if (occupantOmemoDevices.isEmpty) {
    return const TrackResolution(
      track: Track.standard,
      blocked: TrackBlocked.unreachableDevices,
    );
  }
  // The room track is whatever the room's setting says. Not inferred from
  // devices: a room can be configured to be unencrypted while every occupant
  // happens to support OMEMO, and encrypting anyway would contradict the
  // person who owns the room.
  return const TrackResolution(track: Track.standard, blocked: null);
}

/// Roster change worth showing in the room's member list.
enum OccupantChange { joined, left, renamed, promoted, demoted, unchanged }

/// Compares two occupant lists into the changes to show.
///
/// Diffs rather than a full log, because a room of thirty people produces a
/// presence storm on every reconnect and a log of all of it is unreadable. The
/// user cares about who is *new* and who *left*.
List<({OccupantChange change, Occupant occupant, String? previousNick})>
    diffOccupants(
  List<Occupant> before,
  List<Occupant> after,
) {
  final changes = <({OccupantChange change, Occupant occupant, String? previousNick})>[];
  final beforeByNick = {for (final o in before) o.nick: o};

  for (final occupant in after) {
    final previous = beforeByNick[occupant.nick];
    if (previous == null) {
      changes.add((change: OccupantChange.joined, occupant: occupant, previousNick: null));
    } else if (previous.role != occupant.role || previous.affiliation != occupant.affiliation) {
      changes.add((
        change: occupant.role == 'moderator' && previous.role != 'moderator'
            ? OccupantChange.promoted
            : occupant.role != 'moderator' && previous.role == 'moderator'
                ? OccupantChange.demoted
                : OccupantChange.unchanged,
        occupant: occupant,
        previousNick: null,
      ));
    }
  }

  for (final occupant in before) {
    if (after.any((o) => o.nick == occupant.nick)) continue;
    changes.add((
      change: OccupantChange.left,
      occupant: occupant,
      previousNick: occupant.nick,
    ));
  }
  return changes;
}
