// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Per-conversation capability resolution (docs/02 §6, docs/03 §6).
//
// Decides which track a chat can use *before* anything is sent, and
// caches the answer briefly so we do not hit the network per message.
// PEP notifications invalidate the cache.

import 'dart:async';

import 'package:logging/logging.dart';
import 'package:moxxmpp/moxxmpp.dart';

import '../crypto/omemo/dual_track_manager.dart';
import '../crypto/omemo/negotiation.dart';
import '../crypto/omemo/protocol.dart';

/// Capability snapshot for one conversation.
class ChatCapabilities {
  const ChatCapabilities({
    required this.mode,
    required this.recipientDevices,
    required this.peerDevices,
    required this.omemoDevices,
    required this.pqDevices,
    required this.checkedAt,
    required this.reliable,
  });

  /// The track to send with.
  final EncMode mode;

  /// Every device the message must be readable by, including our own
  /// other devices (Carbons fan-out).
  final Set<int> recipientDevices;

  /// Devices the peer itself publishes that we can actually encrypt to.
  ///
  /// Kept apart from [recipientDevices], which also carries our own other
  /// devices. Folding the two together made "they have no reachable device"
  /// unreachable *as a verdict*: our own id alone kept the set non-empty, so a
  /// peer whose every bundle had gone stale — 33 of 57 on the account this was
  /// found with — looked perfectly reachable, the send was allowed, and the
  /// rejection arrived later as a cancelled stanza nobody reported.
  final Set<int> peerDevices;

  /// Devices supporting standard OMEMO.
  final Set<int> omemoDevices;

  /// Devices with a usable PQ bundle.
  final Set<int> pqDevices;

  final DateTime checkedAt;

  /// False when the answer rests on incomplete data (e.g. a bundle fetch
  /// failed), which means [mode] must not be trusted for sending.
  final bool reliable;
}

/// Resolves and caches which track each conversation uses.
class CapabilityService {
  CapabilityService({
    required this.tracks,
    required this.ourDeviceId,
    this.ourPqDevices = _noPqDevices,
    this.ttl = const Duration(minutes: 5),
  });

  final Logger _log = Logger('CapabilityService');

  /// Resolves the dual-track managers for the live connection.
  final DualTrackManager Function() tracks;

  /// Our own OMEMO device id, or null before the device exists.
  final Future<int?> Function() ourDeviceId;

  /// Our own B-track device ids, empty when the PQ device is not published.
  ///
  /// Our own devices have to appear in the capability sets too: the
  /// decision requires *every* recipient device to be covered, and a
  /// carbon copy we cannot decrypt is exactly the bug the invariant exists
  /// to prevent.
  final Future<Set<int>> Function() ourPqDevices;

  static Future<Set<int>> _noPqDevices() async => const <int>{};

  final Duration ttl;

  final _cache = <String, ChatCapabilities>{};
  final _inflight = <String, Future<ChatCapabilities>>{};

  /// Drops any cached answer for [jid] (call on PEP change events).
  void invalidate(JID jid) {
    _cache.remove(jid.toBare().toString());
  }

  void invalidateAll() => _cache.clear();

  /// Returns the cached answer if it is still fresh, else resolves.
  ///
  /// Only a *reliable* answer is ever reused. "We could not read their device
  /// list" is a statement about the network at one instant, not a fact about
  /// the contact — and an unreadable snapshot blocks sending — so serving one
  /// from the cache for the whole [ttl] is how a single timeout turns into five
  /// minutes of "this app will not send to this person". A fresh lookup costs
  /// at most [DualTrackManager.deviceListDeadline], and callers that arrive
  /// while one is running still share it.
  Future<ChatCapabilities> forChat(JID jid) {
    final key = jid.toBare().toString();
    final cached = _cache[key];
    if (cached != null &&
        cached.reliable &&
        DateTime.now().difference(cached.checkedAt) < ttl) {
      return Future.value(cached);
    }
    return _inflight[key] ??= _resolve(jid).whenComplete(() {
      _inflight.remove(key);
    });
  }

  Future<ChatCapabilities> _resolve(JID jid) async {
    final bare = jid.toBare();

    // A track's device list must include our own id, otherwise Carbons
    // copies of our messages would be undecryptable.
    final ourId = await ourDeviceId();

    // Read the device list ourselves rather than through moxxmpp: its
    // fetchDeviceList only knows the XEP-0384 spec node, which no real
    // client publishes to, so it silently reported an empty list for
    // everyone. See lib/crypto/omemo/defacto.dart.
    final resolved = await tracks().resolveOmemoDevices(bare);

    // The peer's own usable devices, before ours are folded in. Two different
    // questions: [peerDevices] answers "is there anybody out there to encrypt
    // to", [recipientDevices] answers "who has to be able to read this".
    final peerDevices = <int>{...resolved.devices};
    final devices = <int>{...peerDevices};
    final ours = <int>{};
    if (ourId != null) ours.add(ourId);
    devices.addAll(ours);

    final pqDevices = await tracks().getPqCapableDevices(bare);
    final ourPq = await ourPqDevices();

    // We hold our own OMEMO keys by definition, so our device ids count as
    // OMEMO-capable without a round-trip.
    final omemo = <int>{...resolved.devices, ...ours};

    // Only devices we can actually deliver to count as PQ-capable; a
    // stale capability cache must not upgrade a mixed chat. Our own PQ
    // device only qualifies once its bundle is actually published.
    final pq = <int>{...pqDevices.intersection(devices), ...ourPq}
      ..retainWhere(devices.contains);

    final mode = decideEncMode(
      allDevices: devices,
      pqCapable: pq,
      omemoCapable: omemo,
    );

    final caps = ChatCapabilities(
      mode: mode,
      recipientDevices: devices,
      peerDevices: peerDevices,
      omemoDevices: omemo,
      pqDevices: pq,
      checkedAt: DateTime.now(),
      // An empty device list is a real answer ("this contact has no
      // devices"); an unreadable one is not. Conflating them would send
      // unencrypted mail believing the peer was merely device-less.
      reliable: resolved.listReadable,
    );
    // Warning, not fine: an unreadable device list is the one failure a user
    // experiences as "this app cannot send at all", with no error and no
    // visible cause. The cost is one line per capability refresh, which is
    // bounded by the TTL and happens a handful of times a session.
    _log.warning(
      'caps($bare): ${caps.mode.name} '
      'peerDevices=${caps.peerDevices.length} '
      'devices=${caps.recipientDevices} '
      'pq=${caps.pqDevices} reliable=${caps.reliable}',
    );
    // Not cached when unreliable: an unreadable snapshot is about the network,
    // not the contact, and a cached one would block sending for the whole TTL.
    // See [forChat].
    if (caps.reliable) {
      _cache[bare.toString()] = caps;
    }
    return caps;
  }
}
