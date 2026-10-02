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

import '../omemo/dual_track_manager.dart';
import '../omemo/negotiation.dart';
import '../omemo/protocol.dart';

/// Capability snapshot for one conversation.
class ChatCapabilities {
  const ChatCapabilities({
    required this.mode,
    required this.recipientDevices,
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
    this.ttl = const Duration(minutes: 5),
  });

  final Logger _log = Logger('CapabilityService');

  /// Resolves the dual-track managers for the live connection.
  final DualTrackManager Function() tracks;

  /// Our own OMEMO device id, or null before the device exists.
  final Future<int?> Function() ourDeviceId;

  final Duration ttl;

  final _cache = <String, ChatCapabilities>{};
  final _inflight = <String, Future<ChatCapabilities>>{};

  /// Drops any cached answer for [jid] (call on PEP change events).
  void invalidate(JID jid) {
    _cache.remove(jid.toBare().toString());
  }

  void invalidateAll() => _cache.clear();

  /// Returns the cached answer if it is still fresh, else resolves.
  Future<ChatCapabilities> forChat(JID jid) {
    final key = jid.toBare().toString();
    final cached = _cache[key];
    if (cached != null &&
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
    final omemoDevices = await tracks().aTrack.fetchDeviceList(
      bare.toString(),
    );

    final devices = <int>{...?omemoDevices};
    if (ourId != null) devices.add(ourId);

    final pqDevices = await tracks().getPqCapableDevices(bare);

    // Only devices we can actually deliver to count as PQ-capable; a
    // stale capability cache must not upgrade a mixed chat.
    final pq = pqDevices.intersection(devices);
    final omemo = omemoDevices?.toSet() ?? devices;

    final mode = decideEncMode(
      allDevices: devices,
      pqCapable: pq,
      omemoCapable: omemo,
    );

    final caps = ChatCapabilities(
      mode: mode,
      recipientDevices: devices,
      omemoDevices: omemo,
      pqDevices: pq,
      checkedAt: DateTime.now(),
      reliable: omemoDevices != null,
    );
    _log.fine(
      'caps($bare): ${caps.mode.name} devices=${caps.recipientDevices} '
      'pq=${caps.pqDevices}',
    );
    _cache[bare.toString()] = caps;
    return caps;
  }
}