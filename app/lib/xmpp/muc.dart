// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Group chats (XEP-0045).
//
// A room is identified by the bare JID `room@server` plus our join nick
// (`room@server/nick` in presence). Almost every decision follows from that:
//
//   * Join / leave presence goes to `room@server/ourNick`.
//   * Outgoing group messages go to the *bare* room with `type='groupchat'`
//     (XEP-0045 / Conversations). Private occupant PMs use `type='chat'` to
//     `room@server/theirNick`.
//   * The sender of an incoming message is the *nick* (resource), not the room.
//   * Occupants change without notice. Anything computed once at join time — a
//     device list, a track decision — is stale by the time it is used, so
//     nothing here is cached beyond what the presence stream itself says.
//   * A room is never a roster contact: no subscription, no PEP-as-peer.
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

import '../crypto/omemo/track.dart';
import '../crypto/omemo/track_resolver.dart';

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
    this.realJid,
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

  /// Real bare JID when the room is non-anonymous; null otherwise.
  final String? realJid;

  bool get isModerator => role == 'moderator';
  bool get canSpeak => role == 'moderator' || role == 'participant';

  /// Present in the room now (Conversations `ranks(Role.PARTICIPANT)`).
  ///
  /// Affiliation stubs from `muc#admin` use `role=none` until presence arrives.
  bool get isOnline =>
      role == 'moderator' || role == 'participant' || role == 'visitor';

  /// Whether this occupant may be addressed by others in the room.
  ///
  /// Visitors cannot: a server that let anyone message a visitor would be
  /// broadcasting to somebody who explicitly asked not to be addressed.
  bool get isAddressable => canSpeak && affiliation != 'outcast';

  /// Conversations `User.ranks(Affiliation.MEMBER)` — OMEMO crypto targets.
  bool get isMemberOrAbove =>
      affiliation == 'owner' ||
      affiliation == 'admin' ||
      affiliation == 'member';

  factory Occupant.from(RoomMember member) => Occupant(
    nick: member.nick,
    affiliation: member.affiliation.value,
    role: member.role.value,
    realJid: member.realJid?.toBare().toString(),
  );

  @override
  bool operator ==(Object other) =>
      other is Occupant &&
      other.nick == nick &&
      other.affiliation == affiliation &&
      other.role == role &&
      other.realJid == realJid;

  @override
  int get hashCode => Object.hash(nick, affiliation, role, realJid);
}

/// Conversations `MucOptions.isPrivateAndNonAnonymous`:
/// `muc_membersonly` && `muc_nonanonymous`.
bool isPrivateAndNonAnonymous(Iterable<String> discoFeatures) {
  final features = discoFeatures.toSet();
  return features.contains('muc_membersonly') &&
      features.contains('muc_nonanonymous');
}

/// Conversations `MucOptions.AFFILIATION_RANKS`.
int affiliationRank(String affiliation) {
  switch (affiliation) {
    case 'owner':
      return 4;
    case 'admin':
      return 3;
    case 'member':
      return 2;
    case 'none':
      return 1;
    case 'outcast':
      return 0;
    default:
      return 0;
  }
}

/// Conversations kick gate: owner, or admin who outranks the target.
bool canKickOccupant({
  required String selfAffiliation,
  required Occupant target,
}) {
  if (selfAffiliation == 'owner') return true;
  return affiliationRank(selfAffiliation) >= affiliationRank('admin') &&
      affiliationRank(selfAffiliation) > affiliationRank(target.affiliation);
}

/// Conversations `MucOptions.canInvite`.
bool canInviteToRoom({
  required bool joined,
  required bool membersOnly,
  required bool allowInvites,
  required String selfRole,
}) {
  if (!joined) return false;
  final hasPermission = !membersOnly || selfRole == 'moderator' || allowInvites;
  return hasPermission;
}

/// Conversations `MucOptions.allowPm` with the live self role.
bool allowPrivateMessages({
  required String? allowPmRaw,
  required String selfRole,
}) {
  if (allowPmRaw == null || allowPmRaw.isEmpty) return true;
  switch (allowPmRaw) {
    case 'anyone':
      return true;
    case 'participants':
      // Conversations ranks(Role.PARTICIPANT): participant or moderator.
      return selfRole == 'moderator' || selfRole == 'participant';
    case 'moderators':
      return selfRole == 'moderator';
    default:
      return false;
  }
}

/// What we may do as ourself in a room (Conversations MucOptions gates).
class RoomSelfCapabilities {
  const RoomSelfCapabilities({
    required this.affiliation,
    required this.role,
    required this.joined,
    required this.privateNonAnonymous,
    required this.allowPm,
    required this.canInvite,
    required this.canChangeSubject,
  });

  final String affiliation;
  final String role;
  final bool joined;
  final bool privateNonAnonymous;
  final bool allowPm;
  final bool canInvite;
  final bool canChangeSubject;

  /// XEP-0045 configuration form (`muc#owner`) — owners only.
  bool get canConfigureRoom => joined && affiliation == 'owner';

  bool canKick(Occupant target) =>
      canKickOccupant(selfAffiliation: affiliation, target: target);
}

/// Bare real JIDs to encrypt a groupchat OMEMO message to
/// (Conversations `MucOptions.getMembers`).
List<String> mucCryptoTargets({
  required List<Occupant> occupants,
  required String? ourBareJid,
}) {
  final out = <String>{};
  for (final o in occupants) {
    if (!o.isMemberOrAbove) continue;
    final jid = o.realJid;
    if (jid == null || jid.isEmpty) continue;
    // Skip domain JIDs (Conversations `!u.realJid.isDomainJid()`).
    final at = jid.indexOf('@');
    if (at <= 0) continue;
    if (ourBareJid != null && jid == ourBareJid) continue;
    out.add(jid);
  }
  return out.toList();
}

/// Occupant from a `muc#admin` `<item/>` (Conversations `itemToUser`).
///
/// Affiliation lookups have no full occupant address — [role] defaults to
/// `none` so the stub stays offline until presence overlays it.
Occupant? occupantFromAdminItem(XMLNode item) {
  final jidRaw = item.attributes['jid']?.toString();
  if (jidRaw == null || jidRaw.isEmpty) return null;
  final bare = JID.fromString(jidRaw).toBare().toString();
  // Domain-only JIDs are not people (Conversations `!u.isDomain()`).
  if (!bare.contains('@') || bare.startsWith('@')) return null;
  final affiliation = item.attributes['affiliation']?.toString() ?? 'none';
  final role = item.attributes['role']?.toString() ?? 'none';
  final nickAttr = item.attributes['nick']?.toString();
  final nick = (nickAttr != null && nickAttr.isNotEmpty)
      ? nickAttr
      : bare.split('@').first;
  return Occupant(
    nick: nick,
    affiliation: affiliation,
    role: role,
    realJid: bare,
  );
}

/// Merge affiliation roster with live presence (Conversations `updateUser`).
///
/// Presence wins when the same real JID is online; offline affiliation stubs
/// (`role=none`) remain so OMEMO can still target them.
List<Occupant> mergeRoomMembers({
  required List<Occupant> affiliation,
  required List<Occupant> online,
}) {
  final byKey = <String, Occupant>{};
  for (final o in affiliation) {
    byKey[o.realJid ?? 'nick:${o.nick}'] = o;
  }
  for (final o in online) {
    byKey[o.realJid ?? 'nick:${o.nick}'] = o;
  }
  return byKey.values.toList();
}

/// Member list for the UI — Conversations `getUsers` vs `getOnlineUsers`.
///
/// Private non-anonymous rooms show the full affiliation roster (including
/// offline). Every other room shows only currently present occupants.
List<Occupant> roomMembersForDisplay({
  required bool privateNonAnonymous,
  required List<Occupant> affiliation,
  required List<Occupant> online,
}) {
  if (privateNonAnonymous) {
    return mergeRoomMembers(affiliation: affiliation, online: online);
  }
  return List<Occupant>.of(online);
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

  /// Our occupant address for presence and private PMs.
  ///
  /// Group messages use the bare [roomJid] with `type='groupchat'` instead
  /// (XEP-0045). Confusing the two is the classic silent MUC bug.
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

/// Which track a room message goes out on (standard-path device snapshot).
///
/// Private non-anonymous rooms enumerate affiliation members (including
/// offline). Standard OMEMO is available when any member device is reachable;
/// PQ is decided separately in [XmppService.sendGroupchatOnTrack] because it
/// needs every member to be fully PQ-capable (same bar as 1:1).
TrackResolution resolveRoomTrack({
  required Set<int> occupantOmemoDevices,
  required bool devicesReadable,
  Track requested = Track.standard,
}) {
  if (requested == Track.none) {
    return const TrackResolution(track: Track.none, blocked: null);
  }
  if (!devicesReadable) {
    return TrackResolution(
      track: requested,
      blocked: TrackBlocked.unknownPeers,
    );
  }
  if (occupantOmemoDevices.isEmpty) {
    return TrackResolution(
      track: requested,
      blocked: TrackBlocked.unreachableDevices,
    );
  }
  if (requested == Track.pq) {
    // Device snapshot alone cannot prove every member is PQ-capable; the
    // send path loads each member's bundles. Treat as sendable here so the
    // UI can offer the track; sendGroupchatOnTrack may still refuse.
    return const TrackResolution(track: Track.pq, blocked: null);
  }
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
diffOccupants(List<Occupant> before, List<Occupant> after) {
  final changes =
      <({OccupantChange change, Occupant occupant, String? previousNick})>[];
  final beforeByNick = {for (final o in before) o.nick: o};

  for (final occupant in after) {
    final previous = beforeByNick[occupant.nick];
    if (previous == null) {
      changes.add((
        change: OccupantChange.joined,
        occupant: occupant,
        previousNick: null,
      ));
    } else if (previous.role != occupant.role ||
        previous.affiliation != occupant.affiliation) {
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
