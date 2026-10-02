// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Dual-track manager: A track (standard OMEMO via moxxmpp) plus B track
// (PQ-OMEMO via our own PEP nodes). See docs/02 and docs/03.

import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:moxxmpp/moxxmpp.dart';
import 'package:omemo_dart/omemo_dart.dart' as omemo show OmemoBundle;
import 'package:omemo_dart/omemo_dart.dart' hide OmemoManager, OmemoBundle;
import 'package:xml/xml.dart';

import '../pq/mlkem.dart';
import 'bundle_codec.dart';
import 'defacto.dart';
import 'negotiation.dart';
import 'pq_session.dart';
import 'protocol.dart';

/// Owns the B track's PEP state and the outbound-track decision.
///
/// The A track is fully delegated to moxxmpp's [OmemoManager] (kept
/// byte-compatible with Conversations/Moxxy/Dino); the B track uses
/// parallel PEP nodes ([pomemoDevicesXmlns]/[pomemoBundlesXmlns]) so
/// standard clients never see keys they cannot use.
class DualTrackManager {
  DualTrackManager({
    required this.aTrack,
    required this.pubsubOf,
  });

  final OmemoManager aTrack;
  final PubSubManager Function() pubsubOf;

  /// X25519 identity public key of one B-track device, taken from its
  /// bundle. Returns null when the device publishes no usable bundle.
  ///
  /// This is what binds a session to both identities (invariant 4: the
  /// same key the A track fingerprints).
  Future<List<int>?> deviceById(JID jid, int deviceId) async {
    final bundle = await getPqBundle(jid, deviceId);
    if (bundle == null) return null;
    final device = await deviceFromBundle(bundle);
    if (device == null) return null;
    return await device.ikDh.pk.getBytes();
  }

  /// Loads every B-track device of [jid] as a [PqDevice], ready to
  /// encrypt to.
  ///
  /// Returns an empty list when the peer publishes no PQ bundle, which is
  /// how the negotiation learns they are not PQ-capable.
  Future<List<PqDevice>> loadPqDevices(JID jid) async {
    final devices = await getPqCapableDevices(jid);
    final out = <PqDevice>[];
    for (final id in devices) {
      final bundle = await getPqBundle(jid, id);
      if (bundle == null) continue;
      final device = await deviceFromBundle(bundle);
      if (device != null) out.add(device);
    }
    return out;
  }

  /// Rebuilds a [PqDevice] from its published bundle.
  ///
  /// Only the public halves exist on the wire, so the returned device
  /// carries usable public keys but empty private material — it is safe to
  /// encrypt *to* it, never to decrypt.
  static Future<PqDevice?> deviceFromBundle(PqBundle bundle) async {
    try {
      final spk = base64Decode(bundle.spk);
      final signature = base64Decode(bundle.spkSignature);
      final ik = base64Decode(bundle.ikEncoded);
      final pqSpk = base64Decode(bundle.pqSpk);
      if (spk.length != 32 || ik.length != 32 || signature.length != 64) {
        return null;
      }
      if (pqSpk.length != MlKem768.publicKeyLength) return null;

      final opks = <int, OmemoKeyPair>{};
      for (final e in bundle.prekeys.entries) {
        final bytes = base64Decode(e.value);
        if (bytes.length != 32) continue;
        // Public-only key pair: enough for DH from our side.
        opks[e.key] = OmemoKeyPair.fromBytes(
          bytes,
          // A zero private key never gets used; we only ever read `.pk`.
          List<int>.filled(32, 0),
          KeyPairType.x25519,
        );
      }
      final pqOpks = <int, KemKeyPair>{};
      for (final e in bundle.pqPrekeys.entries) {
        final bytes = base64Decode(e.value);
        if (bytes.length != MlKem768.publicKeyLength) continue;
        pqOpks[e.key] = KemKeyPair(
          publicKey: bytes,
          secretKey: List<int>.filled(MlKem768.secretKeyLength, 0),
        );
      }

      return PqDevice(
        jid: bundle.jid,
        id: bundle.deviceId,
        ikDh: OmemoKeyPair.fromBytes(
          ik,
          List<int>.filled(32, 0),
          KeyPairType.x25519,
        ),
        spk: OmemoKeyPair.fromBytes(
          spk,
          List<int>.filled(32, 0),
          KeyPairType.x25519,
        ),
        spkId: bundle.spkId,
        spkSignature: signature,
        pqSpk: pqSpk,
        pqSpkSecret: const [],
        pqSpkId: bundle.pqSpkId,
        pqSpkSignature: base64Decode(bundle.pqSpkSignature),
        opks: opks,
        pqOpks: pqOpks,
      );
    } catch (_) {
      // A malformed bundle means "not usable", not a crash.
      return null;
    }
  }

/// Device ids in [jid]'s standard OMEMO list whose bundle actually
  /// fetches.
  ///
  /// The de-facto node is tried first, then the XEP-0384 spec node; a
  /// device that lists itself but serves nothing usable is excluded,
  /// because encrypting to it would produce a message nobody can read.
  Future<Set<int>> getOmemoCapableDevices(JID jid) async {
    final ids = await fetchOmemoDeviceIds(jid);
    final result = <int>{};
    for (final id in ids) {
      if (await getOmemoBundle(jid, id) != null) result.add(id);
    }
    return result;
  }

  /// Raw device ids from [jid]'s OMEMO device list, whichever dialect it
  /// published.
  Future<Set<int>> fetchOmemoDeviceIds(JID jid) async {
    final pm = pubsubOf();
    final ids = <int>{};
    for (final node in [omemoDefactoDevicesNode, ...omemoSpecDevicesNodes]) {
      final items = await pm.getItems(jid, node);
      if (!items.isType<List<PubSubItem>>()) continue;
      for (final item in items.get<List<PubSubItem>>()) {
        try {
          final doc = XmlDocument.parse(item.payload.toXml());
          final parsed = parseOmemoDeviceList(doc.rootElement);
          if (parsed != null) ids.addAll(parsed);
        } catch (_) {
          // A payload we cannot read simply contributes nothing.
        }
      }
    }
    return ids;
  }

  /// Fetches one device's standard OMEMO bundle, or null when
  /// absent/malformed.
  ///
  /// omemo_dart has no bundle parser - it receives already-decoded bundles
  /// through an injected fetch function - so this is our own reader. It is
  /// the first code in the project to interpret a bundle written by another
  /// implementation, which is exactly where a wire-format assumption shows
  /// up; hence the two-dialect tolerance in `parseOmemoBundle`.
  ///
  /// Note the item id: real clients publish the bundle under the item
  /// `current`, while moxxmpp uses the device id. Asking for one specific
  /// id and failing on the other would make every peer look incapable, so
  /// the whole node is fetched and whichever item parses is taken.
  Future<omemo.OmemoBundle?> getOmemoBundle(JID jid, int deviceId) async {
    final pm = pubsubOf();
    final nodes = [
      '$omemoDefactoBundlesNode:$deviceId',
      for (final n in omemoSpecBundlesNodes) '$n:$deviceId',
    ];
    for (final node in nodes) {
      final items = await pm.getItems(jid, node);
      if (!items.isType<List<PubSubItem>>()) continue;
      for (final item in items.get<List<PubSubItem>>()) {
        try {
          final doc = XmlDocument.parse(item.payload.toXml());
          return parseOmemoBundle(
            doc.rootElement,
            jid: jid.toBare().toString(),
            deviceId: deviceId,
          );
        } catch (_) {
          // Try the next item, then the next dialect.
        }
      }
    }
    return null;
  }

  /// Publishes our standard-OMEMO bundle in **both** dialects.
  ///
  /// The de-facto form is what real clients read; the spec form is what
  /// moxxmpp's own `publishBundle` writes and what a future client might
  /// adopt. Returns true when at least one form was accepted.
  Future<bool> publishOmemoBundle(
    JID bareJid,
    omemo.OmemoBundle bundle,
  ) async {
    final pm = pubsubOf();
    final ids = await fetchOmemoDeviceIds(bareJid)..add(bundle.id);

    final listResult = await pm.publish(
      bareJid,
      omemoDefactoDevicesNode,
      XMLNode.fromString(deviceListToDefactoXml(ids).toXmlString()),
      id: 'current',
      options: const PubSubPublishOptions(accessModel: 'open'),
    );
    final listOk = listResult.isType<bool>() && listResult.get<bool>();

    final bundleResult = await pm.publish(
      bareJid,
      '$omemoDefactoBundlesNode:${bundle.id}',
      XMLNode.fromString(bundleToDefactoXml(bundle).toXmlString()),
      id: 'current',
      options: const PubSubPublishOptions(accessModel: 'open', maxItems: '1'),
    );
    final bundleOk = bundleResult.isType<bool>() && bundleResult.get<bool>();

    // Also the XEP-0384 spec dialect, through moxxmpp. Its payload bool is
    // `deviceBundlePublish.isType<PubSubError>()` - true means failure.
    bool specOk = false;
    try {
      final spec = await aTrack.publishBundle(bundle);
      specOk = spec.isType<bool>() && !spec.get<bool>();
    } catch (_) {
      specOk = false;
    }

    return listOk && bundleOk || specOk;
  }

  /// PQ-capable device ids of [jid]: present in the B-track device list
  /// *and* serving a retrievable bundle with PQ keys.
  Future<Set<int>> getPqCapableDevices(JID jid) async {
    final pm = pubsubOf();
    final items = await pm.getItems(jid, pomemoDevicesXmlns);
    if (!items.isType<List<PubSubItem>>()) return {};
    final result = <int>{};
    for (final item in items.get<List<PubSubItem>>()) {
      for (final dev in item.payload.children
          .where((c) => c.tag == 'device')) {
        final id = int.tryParse('${dev.attributes['id']}');
        if (id == null) continue;
        final bundle = await getPqBundle(jid, id);
        if (bundle != null && bundle.hasPqKeys) result.add(id);
      }
    }
    return result;
  }

  /// Fetches one device's B-track bundle, or null when absent/broken.
  /// Malformed payloads never throw: they just mean "not PQ-capable".
  Future<PqBundle?> getPqBundle(JID jid, int deviceId) async {
    final pm = pubsubOf();
    final res = await pm.getItem(jid, pomemoBundlesXmlns, '$deviceId');
    if (!res.isType<PubSubItem>()) return null;
    try {
      final doc = XmlDocument.parse(res.get<PubSubItem>().payload.toXml());
      return PqBundle.fromXml(doc.rootElement, jidOfBundle: jid.toBare().toString());
    } catch (_) {
      return null;
    }
  }

  /// Publishes our B-track device list entry + bundle.
  /// Returns true only when the bundle item was accepted.
  ///
  /// Note the two conventions in play: [PubSubManager.publish] yields
  /// `Result<PubSubError, bool>` where **true means success**, whereas
  /// moxxmpp's `OmemoManager.publishBundle` (used for the A track) yields
  /// a bool where **true means failure**. Do not mix them up.
  Future<bool> publishPqBundle(JID bareJid, PqBundle bundle) async {
    final pm = pubsubOf();

    final existing = await pm.getItems(bareJid, pomemoDevicesXmlns);
    final ids = <int>{};
    if (existing.isType<List<PubSubItem>>()) {
      for (final item in existing.get<List<PubSubItem>>()) {
        for (final dev in item.payload.children
            .where((c) => c.tag == 'device')) {
          final id = int.tryParse('${dev.attributes['id']}');
          if (id != null) ids.add(id);
        }
      }
    }
    ids.add(bundle.deviceId);
    final listNode = XMLNode.xmlns(
      tag: 'devices',
      xmlns: pomemoDevicesXmlns,
      children: [
        for (final id in ids)
          XMLNode(tag: 'device', attributes: {'id': '$id'}),
      ],
    );
    final listResult = await pm.publish(
      bareJid,
      pomemoDevicesXmlns,
      listNode,
      id: 'current',
      options: const PubSubPublishOptions(accessModel: 'open'),
    );
    if (!listResult.isType<bool>() || !listResult.get<bool>()) {
      return false;
    }

    final bundleNode =
        XMLNode.fromString(bundle.toXml().toXmlString());
    final bundleResult = await pm.publish(
      bareJid,
      pomemoBundlesXmlns,
      bundleNode,
      id: '${bundle.deviceId}',
      options:
          const PubSubPublishOptions(accessModel: 'open', maxItems: 'max'),
    );
    return bundleResult.isType<bool>() && bundleResult.get<bool>();
  }

  /// Outbound-track decision for one chat. See [decideEncMode].
  Future<EncMode> decideMode({
    required Set<int> allDevices,
    required Set<int> omemoCapable,
    required JID Function(int deviceId) ownerOf,
  }) async {
    final pqCapable = <int>{};
    final byOwner = <String, List<int>>{};
    for (final d in allDevices) {
      final owner = ownerOf(d).toBare().toString();
      (byOwner[owner] ??= []).add(d);
    }
    for (final entry in byOwner.entries) {
      pqCapable.addAll(
        await getPqCapableDevices(JID.fromString(entry.key)),
      );
    }
    return decideEncMode(
      allDevices: allDevices,
      pqCapable: pqCapable.intersection(allDevices),
      omemoCapable: omemoCapable,
    );
  }
}
