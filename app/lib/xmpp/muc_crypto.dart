// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Who a group-chat message is encrypted *to* (docs/10 §6).
//
// muc.dart answers "can a room message be delivered". This file answers "to
// whom, and with what guarantee" — the question muc.dart's `resolveRoomTrack`
// answers with a bare device count, which is why it stops one step short.
//
// The invariant, carried over from track_resolver.dart unchanged in shape:
//
//   * never silently substitute a weaker track,
//   * never send plaintext because a lookup was slow,
//   * never report a protection the message does not have.
//
// The room version *is* weaker, and says so rather than hiding it. A 1:1
// conversation needs every device of the one recipient, because a single
// unreadable device means somebody's second phone does not get the message.
// A room cannot work that way: any room containing one person with OMEMO
// switched off would be permanently unsendable, which is most rooms. So a
// room message is encrypted for the occupants who can open it, and the rest
// see ciphertext. That is a real difference in what the two guarantees mean,
// and the UI has to be able to state which one it has — hence
// `unreadableOccupants` rather than a boolean.
//
// What is *not* relaxed: the room's track is never chosen on the user's
// behalf, and a partial or stale roster blocks exactly as an unreadable
// device list blocks for 1:1. PQ is offered for private non-anonymous rooms
// when every member is fully PQ-capable (checked at send time).

import '../crypto/omemo/track.dart';
import '../crypto/omemo/track_resolver.dart';
import 'muc.dart';

/// One occupant of a room, as far as encryption is concerned.
///
/// Only the facts a recipient decision needs. Role and affiliation are not
/// repeated here: they belong to [Occupant], and a second copy would let the
/// two disagree about who may be addressed.
class OccupantDevice {
  const OccupantDevice({
    required this.nick,
    required this.realJid,
    required this.bundleReachable,
  });

  /// The room-local nickname. The only thing a message from them can be
  /// attributed to, and the only thing that identifies them inside the room.
  final String nick;

  /// Their real bare JID, or null when the room does not publish it.
  ///
  /// Null is neither an error nor a transient failure: XEP-0045 lets a room
  /// occupy a member with the real JID withheld from us, and plenty of rooms
  /// are configured that way. What it does mean is that there is no address to
  /// put in a recipient list, so nothing can be encrypted *to* them — not
  /// "not right now", but never, as far as this message is concerned.
  final String? realJid;

  /// Whether at least one of this occupant's OMEMO bundles answered.
  ///
  /// Per occupant, not per device, and deliberately so: a room message can
  /// only usefully ask "is anybody in there reachable at all". It is the right
  /// granularity for the room path and too coarse for a private message to
  /// one person, which is a 1:1 conversation wearing a room address — see
  /// `resolvePrivateToOccupant`.
  final bool bundleReachable;

  /// Whether this occupant may be counted as a recipient.
  ///
  /// A published JID *and* a reachable bundle, as two conditions rather than
  /// one, because a null JID has to be treated as unreachable rather than as
  /// "unknown but probably fine". Counting it the other way is how a client
  /// ends up promising that everyone in the room can read a message it has no
  /// way of addressing anyone with.
  ///
  /// [bundleReachable] is allowed to be true alongside a null [realJid] so a
  /// mapping mistake upstream surfaces here as a contradiction instead of
  /// being quietly normalised away. The constructor records what was observed;
  /// this getter records what may be acted on.
  bool get isReachable => realJid != null && bundleReachable;

  @override
  bool operator ==(Object other) =>
      other is OccupantDevice &&
      other.nick == nick &&
      other.realJid == realJid &&
      other.bundleReachable == bundleReachable;

  @override
  int get hashCode => Object.hash(nick, realJid, bundleReachable);

  @override
  String toString() =>
      'OccupantDevice($nick, realJid: $realJid, '
      'reachable: $bundleReachable)';
}

/// The room as it was read at one moment.
///
/// A value rather than a live lookup because the decision has to be made
/// against something fixed: a roster read twice, once to decide and once to
/// send, can differ, and then the guarantee we described is not the one we
/// delivered.
class OccupantSnapshot {
  const OccupantSnapshot({
    required this.occupants,
    required this.readAt,
    required this.complete,
    required this.joined,
  });

  /// Every occupant the read produced, including our own entry — the service
  /// lists us, and callers are expected to exclude us by nick.
  final List<OccupantDevice> occupants;

  /// When this was read.
  final DateTime readAt;

  /// False when the read did not finish: a bundle fetch that failed, a page of
  /// the roster that did not arrive, a mapping that produced nothing for part
  /// of the room. Distinct from "we looked and there was nothing there", which
  /// is a complete read that happens to be empty.
  final bool complete;

  /// Whether we are in the room right now.
  final bool joined;

  /// How old an occupant list may be before we stop acting on it.
  ///
  /// A guess, and the direction of the error matters more than the value. Too
  /// short and a quiet room — one where presence has not moved, so the
  /// snapshot is never refreshed — starts refusing to send for a reason that
  /// is not real; the caller recovers by re-reading presence and deciding
  /// again, which for a genuinely quiet room succeeds immediately. Too long and
  /// we encrypt to a roster that has since changed: somebody who left can
  /// still read it, somebody who joined never sees it, and the sentence we
  /// showed the sender before pressing send is no longer true. Erring short
  /// costs a round-trip; erring long costs the claim.
  static const maxAge = Duration(minutes: 2);

  /// Whether this list is too old to decide from.
  ///
  /// A read dated in the future — a clock that disagrees with the server's —
  /// is not stale. Blocking on that would refuse sends for a condition we
  /// cannot even detect, which is the opposite of what this rule is for.
  bool isStale(DateTime now, {Duration maxAge = OccupantSnapshot.maxAge}) =>
      now.difference(readAt) >= maxAge;

  /// Whether this snapshot describes the room as it is now: we are in it, the
  /// read finished, and it is not too old to act on.
  bool describesRoomNow(
    DateTime now, {
    Duration maxAge = OccupantSnapshot.maxAge,
  }) => joined && complete && !isStale(now, maxAge: maxAge);
}

/// Resolves what a room message may be sent on, against one snapshot.
///
/// [ourNick] is required and nullable on purpose. The roster includes us, and a
/// decision that counted our own devices would report a room of one as having
/// a reachable recipient — a message the service delivers to nobody, stored and
/// labelled as sent. Passing null is an explicit claim that the snapshot holds
/// no entry of ours; not passing anything is not an option.
TrackResolution resolveRoomSend({
  required Track requested,
  required OccupantSnapshot snapshot,
  required String? ourNick,
  Duration maxAge = OccupantSnapshot.maxAge,
  DateTime? now,
}) {
  final at = now ?? DateTime.now();

  // Deliberate plaintext is decided before anything is known about the room,
  // for the reason track_resolver.dart gives: refusing it would be overruling
  // a decision the user was warned about and made anyway. What makes it
  // non-silent is the room send path confirming it first, which is the UI's
  // job and not something this file can check.
  if (requested == Track.none) {
    return const TrackResolution(track: Track.none, blocked: null);
  }

  // Not in the room: there is no roster to decide against, because the service
  // that owns the roster has not accepted our join. Reported as unknownPeers
  // rather than as a device problem — telling the user to go and fix somebody's
  // devices when the fault is our own join being in flight sends them to the
  // wrong place.
  if (!snapshot.joined) {
    return TrackResolution(
      track: requested,
      blocked: TrackBlocked.unknownPeers,
    );
  }

  // A partial list blocks, exactly as an unreadable one does for 1:1.
  //
  // Silently sending in the clear because we could not read half the room's
  // device list is the worst outcome available here: a room's audience is a
  // group, so the message that escapes is the one that was said in front of
  // people. A stale list blocks for the same reason — an hour-old list is an
  // absent one in everything but name.
  if (!snapshot.complete || snapshot.isStale(at, maxAge: maxAge)) {
    return TrackResolution(
      track: requested,
      blocked: TrackBlocked.unknownPeers,
    );
  }

  // One reachable occupant device is enough for standard OMEMO, unlike a 1:1
  // conversation. PQ still needs every member fully PQ-capable — that bar is
  // checked at send time (sendGroupchatOnTrack), using the affiliation list.
  //
  // What the resulting guarantee is: everyone in the room whose bundle
  // answered can open the message, and the server — which holds ciphertext
  // only — cannot. What it is not: that every occupant can read it. A room
  // where one person has OMEMO off still sends, and that person sees an
  // unreadable bubble while everyone else sees a normal conversation. That
  // is the trade, and `unreadableOccupants` exists so the trade can be shown
  // to the sender before they make it rather than discovered afterwards.
  //
  // Our own devices are excluded: the service delivers to every occupant
  // except the sender, so a room whose only reachable device is ours has
  // nobody to encrypt to.
  final reachable = snapshot.occupants.any(
    (o) => o.nick != ourNick && o.isReachable,
  );
  if (!reachable) {
    return TrackResolution(
      track: requested,
      blocked: TrackBlocked.unreachableDevices,
    );
  }

  return TrackResolution(track: requested, blocked: null);
}

/// The occupants of one room who cannot read a message sent now.
class RoomUnreadable {
  const RoomUnreadable({required this.occupants, required this.knowsEveryone});

  /// Occupants with no usable bundle, or no published JID to encrypt to.
  final List<OccupantDevice> occupants;

  /// False when the roster was partial, too old, or we are not in the room.
  ///
  /// Separate from [occupants] because the two are different claims. An
  /// incomplete read that found nobody unreadable has not established that
  /// everybody can read this; it has established that we looked at part of
  /// the room. Collapsing them is how "everyone in the room can read this"
  /// gets said about a roster that was never read.
  final bool knowsEveryone;

  int get count => occupants.length;

  List<String> get nicks => [for (final o in occupants) o.nick];

  /// What the composer can say before the message is sent.
  ///
  /// Phrasing kept here rather than in the widgets so it can be read and
  /// reviewed as a claim about recipients, which is the part the sender cannot
  /// check for themselves.
  String get summary {
    if (!knowsEveryone) {
      return occupants.isEmpty
          ? 'We could not read the whole room, so we cannot say who can read '
                'this.'
          : 'At least ${occupants.length} in this room cannot read this, and '
                'we could not check the rest.';
    }
    return occupants.isEmpty
        ? 'Everyone in the room can read this.'
        : '${occupants.length} ${occupants.length == 1 ? 'person' : 'people'} '
              'in this room cannot read this: ${nicks.join(', ')}.';
  }
}

/// Who in the room cannot read a message sent now.
///
/// [ourNick] is required and nullable for the reason it is on
/// [resolveRoomSend], and here it matters even more visibly: without it our
/// own occupant entry appears in a list telling the sender they cannot read
/// their own message.
RoomUnreadable unreadableOccupants({
  required OccupantSnapshot snapshot,
  required String? ourNick,
  Duration maxAge = OccupantSnapshot.maxAge,
  DateTime? now,
}) {
  final at = now ?? DateTime.now();
  return RoomUnreadable(
    occupants: [
      for (final o in snapshot.occupants)
        if (o.nick != ourNick && !o.isReachable) o,
    ],
    knowsEveryone: snapshot.describesRoomNow(at, maxAge: maxAge),
  );
}

/// Why a message to one occupant cannot be addressed at all.
///
/// Not a [TrackBlocked] because none of these is about a device. Each is a
/// statement about whether the stanza may name this person, and reporting one
/// as a device problem sends the user off to fix the wrong thing.
enum PrivateRefusal {
  /// The room has nobody by that name.
  notPresent,

  /// The occupant is a visitor, or has been banned from the room.
  notAddressable,

  /// We are not in the room, or its roster is partial or too old to act on.
  audienceUnknown,

  /// The address would not name an occupant.
  malformedAddress,
}

/// A private message to one occupant, and the decisions behind it.
class PrivateRoomSend {
  const PrivateRoomSend({
    required this.address,
    required this.toJid,
    required this.resolution,
    required this.refusal,
  });

  /// `room@server/ourNick/targetNick`, non-null only when [canSend].
  ///
  /// Null rather than an address the caller could use regardless: handing out
  /// the address of a message we just refused is how "this person asked not to
  /// be addressed" gets overridden by a caller that read the wrong field.
  final String? address;

  /// The JID to encrypt to, null unless [canSend].
  ///
  /// Not the same as [address]: the stanza goes to the room, which is what
  /// lets the service deliver to the right occupant, while the ciphertext is
  /// for this bare JID's devices. A private message whose two disagree is
  /// readable by the occupant the service picked and unreadable by anybody
  /// else.
  final String? toJid;

  /// The encryption decision for that one person.
  final TrackResolution resolution;

  /// Why the address itself is not allowed, or null.
  final PrivateRefusal? refusal;

  bool get canSend => refusal == null && resolution.canSend;
}

/// Resolves a message addressed to one occupant of a room.
///
/// [target] is the occupant as the roster last reported them, or null when the
/// roster has nobody by that name — a distinction the caller can make and this
/// function cannot, which is why it is passed in rather than looked up.
///
/// The audience here is one person again, so the 1:1 rule applies: this person
/// must be reachable, and a reachability rule relaxed for a room would be a
/// rule that quietly survived the narrowing. The remaining risk in this path is
/// one a room path does not have — the address names a *nick*, and the service
/// resolves it to whoever holds that nick when the message arrives, so a stale
/// roster can put a message encrypted to A in front of B.
PrivateRoomSend resolvePrivateToOccupant({
  required String roomJid,
  required String ourNick,
  required String targetNick,
  required Occupant? target,
  required OccupantSnapshot snapshot,
  required Track requested,
  Duration maxAge = OccupantSnapshot.maxAge,
  DateTime? now,
}) {
  final at = now ?? DateTime.now();
  final device = _deviceFor(snapshot.occupants, targetNick);
  final resolution = _privateResolution(
    requested: requested,
    device: device,
    audienceKnown: snapshot.describesRoomNow(at, maxAge: maxAge),
  );

  // The single place a refusal becomes a [PrivateRoomSend].
  //
  // Built through a function rather than returned from each branch because the
  // resolution is computed *before* any of the branch conditions, so a branch
  // that only checked its own reason would hand out an address for a stanza the
  // resolution had already blocked — post-quantum to a room being the case that
  // actually happened. [PrivateRoomSend.address] promises to be null unless
  // [PrivateRoomSend.canSend], and a promise kept in one function is a promise
  // that survives the next branch somebody adds.
  PrivateRoomSend refused(PrivateRefusal why) => PrivateRoomSend(
    address: null,
    toJid: null,
    resolution: resolution,
    refusal: why,
  );

  PrivateRoomSend allowed({required String address, required String? toJid}) {
    // Belt and braces on top of `refused`: a resolution can block on its own,
    // with no branch having anything to say about it.
    if (!resolution.canSend) {
      return PrivateRoomSend(
        address: null,
        toJid: null,
        resolution: resolution,
        refusal: null,
      );
    }
    return PrivateRoomSend(
      address: address,
      toJid: toJid,
      resolution: resolution,
      refusal: null,
    );
  }

  // An address that does not name an occupant: a room JID that is not bare, a
  // missing nickname, or a nickname containing a slash, which XEP-0045's
  // `room/nick/occupant` form cannot express. The service accepts such a stanza
  // and delivers it to nobody — the one failure here that leaves the sender
  // with no evidence at all, which is why it is checked before anything else.
  if (roomJid.contains('/') ||
      ourNick.isEmpty ||
      targetNick.isEmpty ||
      targetNick.contains('/')) {
    return refused(PrivateRefusal.malformedAddress);
  }

  // Refuse on an unknown roster even though the address could still be built.
  // A nickname is not an identity: the service resolves it at delivery, so a
  // roster that was true a minute ago may name a different person now, and the
  // message would be encrypted to the old one's devices.
  if (!snapshot.describesRoomNow(at, maxAge: maxAge)) {
    return refused(PrivateRefusal.audienceUnknown);
  }

  // Not in the room: nobody to address, and the service has no reason to
  // resolve a nickname for an occupant we are not.
  if (target == null) {
    return refused(PrivateRefusal.notPresent);
  }

  // A visitor asked not to be addressed and an outcast was removed from the
  // room; a server that let a private message through would be overriding what
  // the role means, and the surprise lands on the person who declined. The
  // refusal carries their devices being perfectly reachable — addressability
  // is about the room, not about crypto.
  if (!target.isAddressable) {
    return refused(PrivateRefusal.notAddressable);
  }

  return allowed(
    address: '$roomJid/$ourNick/$targetNick',
    toJid: device?.realJid,
  );
}

/// The device record for [nick], or null.
///
/// Null means two different things — an occupant we never looked up, and an
/// occupant we looked up and found nothing for — and the private resolver
/// treats it as the first of those. A mapping gap is not a positive finding of
/// "this person has no devices", so it blocks as unknownPeers rather than
/// unreachableDevices.
OccupantDevice? _deviceFor(List<OccupantDevice> occupants, String nick) {
  for (final o in occupants) {
    if (o.nick == nick) return o;
  }
  return null;
}

TrackResolution _privateResolution({
  required Track requested,
  required OccupantDevice? device,
  required bool audienceKnown,
}) {
  // The same two exceptions as the room path, in the same order, so that
  // "what does this client do with NO and PO in a room" has one answer
  // whichever entry point it came in through.
  if (requested == Track.none) {
    return const TrackResolution(track: Track.none, blocked: null);
  }
  if (!audienceKnown) {
    return TrackResolution(
      track: requested,
      blocked: TrackBlocked.unknownPeers,
    );
  }
  // No record at all is an absence of information rather than a finding: the
  // roster lists this occupant but nothing ever resolved their devices, and
  // calling that "they have no devices" would send the user to a device that
  // may be working perfectly.
  if (device == null) {
    return TrackResolution(
      track: requested,
      blocked: TrackBlocked.unknownPeers,
    );
  }
  // We did look, and could not reach them — including the case XEP-0045 allows
  // where the room never published their real JID, so there is no address to
  // encrypt to at all.
  if (!device.isReachable) {
    return TrackResolution(
      track: requested,
      blocked: TrackBlocked.unreachableDevices,
    );
  }
  // PQ capability for this one occupant is checked at send time (1:1
  // capabilitiesFor on their real JID).
  return TrackResolution(track: requested, blocked: null);
}
