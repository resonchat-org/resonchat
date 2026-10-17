// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Per-conversation capability resolution (docs/02 §6, docs/03 §6).
//
// Classic OMEMO (A) and OMEMO2/PQ (B) are independent stacks — same model as
// monocles `deviceIds` vs `omemo2DeviceIds`. Separate PEP nodes, separate
// lists, no intersection. A contact can be PQ-capable with an empty classic
// list and vice versa.

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
    this.classicReliable = true,
    this.pqReliable = true,
  });

  /// Legacy auto-track verdict (A/B mix). UI track choice uses [resolveTrack].
  final EncMode mode;

  /// Classic A-track recipients (peer classic devices + our classic id).
  final Set<int> recipientDevices;

  /// Peer's classic OMEMO devices only (never mixed with OMEMO2 ids).
  final Set<int> peerDevices;

  /// Devices supporting standard OMEMO (classic list + our id).
  final Set<int> omemoDevices;

  /// Peer's OMEMO2 / PQ device ids from the B-track PEP list alone.
  ///
  /// Independent of [peerDevices] / [omemoDevices]. Non-empty means monocles
  /// (or us) published on `urn:monocles:omemo-pq:1:devices`.
  final Set<int> pqDevices;

  final DateTime checkedAt;

  /// True when at least one track's device list was readable.
  final bool reliable;

  /// Classic axolotl list answered (possibly empty).
  final bool classicReliable;

  /// OMEMO2 device list answered (possibly empty).
  final bool pqReliable;
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

  /// Our own classic OMEMO device id, or null before the device exists.
  final Future<int?> Function() ourDeviceId;

  /// Our own B-track device ids once published (independent of classic id).
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

    final ourId = await ourDeviceId();
    final ourPq = await ourPqDevices();

    // Two independent PEP reads — never gate one on the other.
    final classic = await tracks().resolveOmemoDevices(bare);
    final pqList = await tracks().fetchPqDeviceIds(bare);

    final peerClassic = <int>{...classic.devices};
    final peerPq = <int>{...pqList.devices};

    final ours = <int>{};
    if (ourId != null) ours.add(ourId);

    final omemo = <int>{...peerClassic, ...ours};
    // A-track recipients only. B-track ids stay in [pqDevices].
    final recipientDevices = <int>{...peerClassic, ...ours};

    // Auto-mode still needs a combined view for carbons / mixed chats, but
    // [pqDevices] itself stays peer-B-only for UI and resolveTrack.
    final modeDevices = <int>{...recipientDevices, ...peerPq, ...ourPq};
    final modePq = <int>{...peerPq, ...ourPq};
    final mode = decideEncMode(
      allDevices: modeDevices,
      pqCapable: modePq,
      omemoCapable: omemo,
    );

    final classicReliable = classic.listReadable;
    final pqReliable = pqList.listReadable;
    final reliable = classicReliable || pqReliable;

    final caps = ChatCapabilities(
      mode: mode,
      recipientDevices: recipientDevices,
      peerDevices: peerClassic,
      omemoDevices: omemo,
      pqDevices: peerPq,
      checkedAt: DateTime.now(),
      reliable: reliable,
      classicReliable: classicReliable,
      pqReliable: pqReliable,
    );
    _log.warning(
      'caps($bare): ${caps.mode.name} '
      'classic=${caps.peerDevices} '
      'pq=${caps.pqDevices} '
      'classicOk=$classicReliable pqOk=$pqReliable',
    );
    if (caps.reliable) {
      _cache[bare.toString()] = caps;
    }
    return caps;
  }
}
