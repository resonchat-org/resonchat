// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Owns the local B-track (PQ-OMEMO) device and wires it into the message
// path: publish our bundle, encrypt on the B track when the chat qualifies,
// and decrypt inbound PQ messages.
//
// The A track keeps going through moxxmpp untouched, so standard clients
// stay interoperable.

import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:moxxmpp/moxxmpp.dart';
import 'package:xml/xml.dart';

import '../omemo/bundle_codec.dart';
import '../omemo/dual_track_manager.dart';
import '../omemo/message_codec.dart';
import '../omemo/pq_message_layer.dart';
import '../omemo/pq_session.dart';
import '../omemo/protocol.dart';
import '../pq/liboqs_mlkem.dart';

/// The local B-track device plus its session and message layer.
class BTrackSession {
  BTrackSession({
    required this.device,
    required this.sessions,
    required this.layer,
  });

  final PqDevice device;
  final PqSessionManager sessions;
  final PqMessageLayer layer;
}

class BTrackManager {
  BTrackManager({
    required this.tracks,
    required this.pubsubOf,
  });

  final Logger _log = Logger('BTrackManager');
  final DualTrackManager Function() tracks;
  final PubSubManager? Function() pubsubOf;

  BTrackSession? _session;

  /// Our B-track device once it exists.
  PqDevice? get device => _session?.device;

  bool get ready => _session != null;

  /// Creates (or restores) the local B-track device and publishes it.
  ///
  /// Called after connect; safe to call again to refresh the bundle.
  Future<bool> initialise(String bareJid, {int opkCount = 20}) async {
    final pm = pubsubOf();
    if (pm == null) {
      _log.warning('no PubSub manager; B track unavailable');
      return false;
    }

    final device = await PqDevice.generate(
      bareJid,
      opkCount: opkCount,
      pqOpkCount: 5,
      kem: MlKem768Provider.instance.kem,
    );
    final sessions = PqSessionManager(kem: MlKem768Provider.instance.kem);
    // Identity keys come from the sender's published bundle.
    final layer = PqMessageLayer(
      ownDevice: device,
      sessions: sessions,
      senderIkOf: (deviceId) async {
        final d = await tracks()
            .deviceById(JID.fromString(bareJid), deviceId);
        if (d == null) {
          throw StateError('no PQ bundle for $bareJid/$deviceId');
        }
        return d;
      },
    );
    _session = BTrackSession(device: device, sessions: sessions, layer: layer);

    final published = await publish();
    _log.info(
      published ? 'PQ bundle published' : 'PQ bundle publish failed',
    );
    return published;
  }

  /// Publishes our B-track device list entry and bundle to PEP.
  Future<bool> publish() async {
    final session = _session;
    final pm = pubsubOf();
    if (session == null || pm == null) return false;

    final bundle = await _toBundle(session.device);
    final bare = JID.fromString(session.device.jid);

    // Merge our id into the existing device list rather than replacing it,
    // so other devices of ours survive.
    final ids = <int>{};
    final existing = await pm.getItems(bare, pomemoDevicesXmlns);
    if (existing.isType<List<PubSubItem>>()) {
      for (final item in existing.get<List<PubSubItem>>()) {
        for (final dev in item.payload.children
            .where((c) => c.tag == 'device')) {
          final id = int.tryParse('${dev.attributes['id']}');
          if (id != null) ids.add(id);
        }
      }
    }
    ids.add(session.device.id);

    final listResult = await pm.publish(
      bare,
      pomemoDevicesXmlns,
      XMLNode.xmlns(
        tag: 'devices',
        xmlns: pomemoDevicesXmlns,
        children: [
          for (final id in ids)
            XMLNode(tag: 'device', attributes: {'id': '$id'}),
        ],
      ),
      id: 'current',
      options: const PubSubPublishOptions(accessModel: 'open'),
    );
    if (!listResult.isType<bool>() || !listResult.get<bool>()) {
      return false;
    }

    final bundleResult = await pm.publish(
      bare,
      pomemoBundlesXmlns,
      XMLNode.fromString(bundle.toXml().toXmlString()),
      id: '${session.device.id}',
      options: const PubSubPublishOptions(accessModel: 'open', maxItems: 'max'),
    );
    return bundleResult.isType<bool>() && bundleResult.get<bool>();
  }

  /// Encrypts [plaintext] for every PQ-capable device of [peerJid].
  ///
  /// Returns null when the peer has no PQ devices or nothing could be
  /// encrypted; the caller must then fall back to the A track rather than
  /// send something unreadable.
  Future<PqEncryptedMessage?> encryptIfPossible({
    required String peerJid,
    required String plaintext,
  }) async {
    final session = _session;
    if (session == null) return null;

    final bare = JID.fromString(peerJid).toBare();
    final devices = await tracks().loadPqDevices(bare);
    if (devices.isEmpty) return null;

    final outgoing = await session.layer.encrypt(
      plaintext: plaintext,
      recipients: devices,
    );
    return outgoing?.stanza;
  }

  /// Decrypts an inbound PQ `<encrypted>` element; null when it is not for
  /// us (a different device, or not a B-track message at all).
  Future<String?> decryptIfPossible(XmlElement element) async {
    final session = _session;
    if (session == null) return null;

    final message = PqEncryptedMessage.fromXml(element);
    if (!message.keys.any((k) => k.recipientDeviceId == session.device.id)) {
      return null;
    }
    return session.layer.decrypt(message);
  }

  /// Whether [peerJid] is fully PQ-capable, i.e. every one of its devices
  /// serves a PQ bundle.
  Future<bool> isPeerPqCapable(String peerJid) async {
    final bare = JID.fromString(peerJid).toBare();
    final devices = await tracks().loadPqDevices(bare);
    return devices.isNotEmpty;
  }

  Future<PqBundle> _toBundle(PqDevice device) async {
    final prekeys = <int, String>{};
    for (final e in device.opks.entries) {
      prekeys[e.key] = base64Encode(await e.value.pk.getBytes());
    }
    final pqPrekeys = <int, String>{};
    for (final e in device.pqOpks.entries) {
      pqPrekeys[e.key] = base64Encode(e.value.publicKey);
    }
    return PqBundle(
      deviceId: device.id,
      jid: device.jid,
      spk: base64Encode(await device.spk.pk.getBytes()),
      spkId: device.spkId,
      spkSignature: base64Encode(device.spkSignature),
      ikEncoded: base64Encode(await device.ikDh.pk.getBytes()),
      prekeys: prekeys,
      pqSpkId: device.pqSpkId,
      pqSpk: base64Encode(device.pqSpk),
      pqSpkSignature: base64Encode(device.pqSpkSignature),
      pqPrekeys: pqPrekeys,
    );
  }
}