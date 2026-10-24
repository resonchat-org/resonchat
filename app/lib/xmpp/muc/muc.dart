// Copyright (C) 2026 ResonChat contributors.
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
//     device list, a track decision — is stale by the time it is used. The
//     last display roster is kept so the read ring can draw before the next
//     presence wave, then replaced when that wave arrives.
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

import 'dart:convert';

import 'package:moxxmpp/moxxmpp.dart';

import 'package:resonchat/crypto/dual/track.dart';
import 'package:resonchat/crypto/dual/track_resolver.dart';

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
    this.show,
    this.reason,
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

  /// MUC presence `<show/>` (Gajim `GroupchatParticipant.show`).
  ///
  /// Null when offline / unavailable — not roster presence.
  final PresenceShow? show;

  /// Optional ban reason from `muc#admin` (outcast list / ban set).
  final String? reason;

  bool get isModerator => role == 'moderator';
  bool get canSpeak => role == 'moderator' || role == 'participant';

  /// Present in the room now (Conversations `ranks(Role.PARTICIPANT)`).
  ///
  /// Affiliation stubs from `muc#admin` use `role=none` until presence arrives.
  bool get isOnline =>
      role == 'moderator' || role == 'participant' || role == 'visitor';

  /// Dot colour for member lists: online show, or grey when offline.
  PresenceShow? get presenceForDot =>
      isOnline ? (show ?? PresenceShow.online) : null;

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
    show: member.show,
  );

  @override
  bool operator ==(Object other) =>
      other is Occupant &&
      other.nick == nick &&
      other.affiliation == affiliation &&
      other.role == role &&
      other.realJid == realJid &&
      other.show == show &&
      other.reason == reason;

  @override
  int get hashCode =>
      Object.hash(nick, affiliation, role, realJid, show, reason);
}

/// JSON for the saved member list. Same fields the read ring and the roster
/// need before the next presence wave: nick, affiliation, role, real JID.
String encodeRoomMembers(List<Occupant> occupants) {
  return jsonEncode([
    for (final o in occupants)
      {
        'nick': o.nick,
        'affiliation': o.affiliation,
        'role': o.role,
        if (o.realJid != null) 'realJid': o.realJid,
        if (o.show != null) 'show': o.show!.name,
      },
  ]);
}

List<Occupant> decodeRoomMembers(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is! List) return const [];
  final out = <Occupant>[];
  for (final item in decoded) {
    if (item is! Map) continue;
    final nick = item['nick'];
    final affiliation = item['affiliation'];
    final role = item['role'];
    if (nick is! String || affiliation is! String || role is! String) continue;
    final real = item['realJid'];
    final showName = item['show'];
    PresenceShow? show;
    if (showName is String) {
      for (final value in PresenceShow.values) {
        if (value.name == showName) {
          show = value;
          break;
        }
      }
    }
    out.add(
      Occupant(
        nick: nick,
        affiliation: affiliation,
        role: role,
        realJid: real is String && real.isNotEmpty ? real : null,
        show: show,
      ),
    );
  }
  return out;
}

/// Gajim `AffiliationRoleSortOrder` / roster section keys.
const mucRosterGroupOrder = <String, int>{
  'owner': 0,
  'admin': 1,
  'moderator': 2,
  'participant': 3,
  'visitor': 4,
};

/// Gajim `get_group_from_contact`: owner/admin by affiliation; everyone else
/// by role (`role=none` offline stubs group with participants).
String mucRosterGroupKey(Occupant occupant) {
  if (occupant.affiliation == 'owner' || occupant.affiliation == 'admin') {
    return occupant.affiliation;
  }
  if (occupant.role == 'none') return 'participant';
  return occupant.role;
}

/// Live roster entry for [nick], or null if they are not listed (left without
/// an offline affiliation stub).
Occupant? occupantByNick(GroupChat room, String nick) {
  for (final o in room.occupants) {
    if (o.nick == nick) return o;
  }
  return null;
}

/// Occupants bucketed like Gajim's groupchat roster (section order preserved).
Map<String, List<Occupant>> groupOccupantsForRoster(
  Iterable<Occupant> occupants,
) {
  final buckets = <String, List<Occupant>>{
    for (final key in mucRosterGroupOrder.keys) key: <Occupant>[],
  };
  for (final o in occupants) {
    final key = mucRosterGroupKey(o);
    (buckets[key] ??= <Occupant>[]).add(o);
  }
  for (final list in buckets.values) {
    list.sort((a, b) => a.nick.toLowerCase().compareTo(b.nick.toLowerCase()));
  }
  return {
    for (final key in mucRosterGroupOrder.keys)
      if (buckets[key]!.isNotEmpty) key: buckets[key]!,
  };
}

/// Disco `muc_nonanonymous` — real JIDs visible to everyone in the room.
bool isNonAnonymousRoom(Iterable<String> discoFeatures) =>
    discoFeatures.toSet().contains('muc_nonanonymous');

/// Real JIDs are visible to us: room is non-anonymous, or we are owner/admin
/// (semi-/fully anonymous rooms still expose JIDs to privileged affiliates).
bool canSeeRoomMemberJids({
  required bool nonAnonymous,
  required String selfAffiliation,
}) {
  if (nonAnonymous) return true;
  return selfAffiliation == 'owner' || selfAffiliation == 'admin';
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

/// XEP-0045 role ordering (Gajim / nbxmpp `Role`).
int roleRank(String role) {
  switch (role) {
    case 'moderator':
      return 3;
    case 'participant':
      return 2;
    case 'visitor':
      return 1;
    case 'none':
      return 0;
    default:
      return 0;
  }
}

/// Gajim `is_role_change_allowed`: self must be moderator and not outranked
/// by affiliation (kick / grant-revoke voice).
bool canChangeOccupantRole({
  required String selfRole,
  required String selfAffiliation,
  required Occupant target,
}) {
  if (roleRank(selfRole) < roleRank('moderator')) return false;
  return affiliationRank(selfAffiliation) >=
      affiliationRank(target.affiliation);
}

/// Gajim `is_affiliation_change_allowed` for a desired target affiliation.
bool canChangeOccupantAffiliation({
  required String selfAffiliation,
  required Occupant target,
  required String toAffiliation,
}) {
  if (target.affiliation == toAffiliation) return false;
  if (selfAffiliation == 'owner') return true;
  if (selfAffiliation != 'admin') return false;
  if (toAffiliation == 'owner' || toAffiliation == 'admin') return false;
  return affiliationRank(selfAffiliation) > affiliationRank(target.affiliation);
}

/// Kick (role → none): same gate as other role changes (Gajim moderation).
bool canKickOccupant({
  required String selfRole,
  required String selfAffiliation,
  required Occupant target,
}) => canChangeOccupantRole(
  selfRole: selfRole,
  selfAffiliation: selfAffiliation,
  target: target,
);

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

  /// Gajim Outcasts tab: owners and admins may view/edit the ban list.
  bool get canManageOutcasts =>
      joined && (affiliation == 'owner' || affiliation == 'admin');

  bool canKick(Occupant target) => canKickOccupant(
    selfRole: role,
    selfAffiliation: affiliation,
    target: target,
  );

  bool canChangeRole(Occupant target) => canChangeOccupantRole(
    selfRole: role,
    selfAffiliation: affiliation,
    target: target,
  );

  bool canChangeAffiliation(Occupant target, String toAffiliation) =>
      canChangeOccupantAffiliation(
        selfAffiliation: affiliation,
        target: target,
        toAffiliation: toAffiliation,
      );
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
  final reasonRaw = item.firstTag('reason')?.innerText().trim();
  return Occupant(
    nick: nick,
    affiliation: affiliation,
    role: role,
    realJid: bare,
    reason: (reasonRaw != null && reasonRaw.isNotEmpty) ? reasonRaw : null,
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

/// Member list for the UI.
///
/// When [includeOfflineAffiliates] is true (non-anonymous room, or we are
/// owner/admin and can see JIDs), merge the affiliation roster so offline
/// members appear. Otherwise presence-only (online occupants).
List<Occupant> roomMembersForDisplay({
  required bool includeOfflineAffiliates,
  required List<Occupant> affiliation,
  required List<Occupant> online,
}) {
  if (includeOfflineAffiliates) {
    return mergeRoomMembers(affiliation: affiliation, online: online);
  }
  return List<Occupant>.of(online);
}

/// True when any occupant carries a real bare JID (read rings / OMEMO).
bool roomRosterHasRealJids(Iterable<Occupant> occupants) =>
    occupants.any((o) => (o.realJid ?? '').contains('@'));

/// Local-first display roster for member lists and group read rings.
///
/// Prefer [live] when it is usable; otherwise keep [saved] so opening a room
/// (or a nick-only presence snapshot) cannot blank the UI until the network
/// affiliation / non-anonymous presence catches up.
List<Occupant> resolveRoomRoster({
  required List<Occupant> live,
  required List<Occupant> saved,
}) {
  if (live.isEmpty) return List<Occupant>.of(saved);
  if (!roomRosterHasRealJids(live) && roomRosterHasRealJids(saved)) {
    return List<Occupant>.of(saved);
  }
  return List<Occupant>.of(live);
}

/// Whether a live merge should replace the persisted local roster.
///
/// Never overwrite a JID-bearing saved roster with an empty or nick-only live
/// snapshot.
bool shouldPersistRoomRoster({
  required List<Occupant> live,
  required List<Occupant> saved,
}) {
  if (live.isEmpty) return false;
  if (!roomRosterHasRealJids(live) && roomRosterHasRealJids(saved)) {
    return false;
  }
  return true;
}

/// A room we are in.
class GroupChat {
  const GroupChat({
    required this.roomJid,
    required this.nick,
    required this.occupants,
    this.subject,
    this.joined = false,
    this.canSeeMemberJids = false,
  });

  /// The bare room JID, `room@server`.
  final String roomJid;

  /// Our nickname in this room.
  final String nick;

  /// Display roster: online occupants, plus offline affiliates when
  /// [canSeeMemberJids] is true.
  final List<Occupant> occupants;

  final String? subject;

  final bool joined;

  /// Real JIDs are visible to us (non-anonymous, or we are owner/admin).
  ///
  /// Drives AppBar subtitle: members+online vs online-only.
  final bool canSeeMemberJids;

  /// Affiliated members (owner/admin/member), including offline stubs.
  int get affiliatedMemberCount =>
      occupants.where((o) => o.isMemberOrAbove).length;

  /// Present in the room now.
  int get onlineOccupantCount => occupants.where((o) => o.isOnline).length;

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
    bool? canSeeMemberJids,
  }) {
    return GroupChat(
      roomJid: roomJid,
      nick: nick,
      occupants: occupants ?? this.occupants,
      subject: subject ?? this.subject,
      joined: joined ?? this.joined,
      canSeeMemberJids: canSeeMemberJids ?? this.canSeeMemberJids,
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
/// needs every member to be fully PQ-capable (stricter than 1:1).
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
    // Device snapshot alone cannot prove members are PQ-capable; the send
    // path loads each member's bundles (group still requires every member
    // device — stricter than 1:1's "one peer device" rule). Treat as
    // sendable here so the UI can offer the track; send may still refuse.
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
