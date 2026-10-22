// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Dual-track manager: A track (standard OMEMO via moxxmpp) plus B track
// (PQ-OMEMO via our own PEP nodes). See docs/02 and docs/03.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:logging/logging.dart';
import 'package:moxxmpp/moxxmpp.dart';
import 'package:omemo_dart/omemo_dart.dart';
import 'package:omemo_dart/omemo_dart_axolotl.dart' show AxolotlBundle;
import 'package:omemo_dart/omemo_dart_omemo2.dart'
    show Omemo2Device, Omemo2KyberPreKey, parseMlKem1024PublicKey;
import 'package:xml/xml.dart';

import 'package:resonchat/crypto/axolotl/defacto.dart';
import 'package:resonchat/crypto/dual/bounded.dart';
import 'package:resonchat/crypto/dual/negotiation.dart';
import 'package:resonchat/crypto/omemo2/bundle_codec.dart';
import 'package:resonchat/crypto/omemo2/mlkem.dart';
import 'package:resonchat/crypto/omemo2/omemo2_bundle_verify.dart';
import 'package:resonchat/crypto/omemo2/pq_session.dart';
import 'package:resonchat/crypto/omemo2/protocol.dart';

final Logger _log = Logger('DualTrackManager');

/// How many device bundles are fetched at once.
///
/// **Three, and the number was found the hard way.** Eight was the first value,
/// on the reasoning that eight concurrent IQs is unremarkable. Against a real
/// server under real load it was not: the socket was aborted mid-resolution
/// (`SocketException ... abort, errno = 103`). A dropped socket turns every
/// in-flight capability read into a failure, so the cost of a burst was not
/// latency — it was `caps.reliable == false` and the standard track resolving to
/// something weaker. Three keeps the round-trips few enough to finish before a
/// busy server gives up on us.
const int kBundleFetchConcurrency = 3;

/// How long a device list may take before we treat it as unreadable.
///
/// **Thirty seconds, and twelve was a number that refused real contacts.** The
/// resolution is not one round-trip: every listed device needs its own bundle
/// probe, and a probe asks the de-facto node first and the spec node second, so
/// a device that publishes one dialect costs two IQs. At
/// [kBundleFetchConcurrency] — three, because a wider burst aborts the socket
/// (see above) — a contact with thirty-odd published ids, which is what an
/// account collects over a few reinstalls, spends twenty round-trips on the
/// sweep alone.
///
/// What a timeout produces is not a slow answer, it is *"we know nothing"*, and
/// that blocks sending (`TrackBlocked.unknownPeers`). So twelve seconds made a
/// busy but healthy contact unsendable, with a dialog that offers a substitute
/// track that cannot be carried out either. Thirty still turns a genuinely
/// stalled connection into a refusal the user can read and retry; it just no
/// longer converts a large device list into one.
const Duration kDeviceListDeadline = Duration(seconds: 30);

/// PEP publish/fetch for both stacks, plus the outbound-track decision.
///
/// A and B are independent namespaces with parallel APIs:
/// `publishOmemoBundle` / `publishOmemoDeviceIds` (classic) and
/// `publishPqBundle` / `publishPqDeviceIds` (OMEMO2). Session lifecycle
/// stays outside: [XmppConnection.ensureOmemoDevice] for A,
/// [BTrackManager] for B — each builds a bundle then calls these methods.
class DualTrackManager {
  DualTrackManager({required this.aTrack, required this.pubsubOf});

  final OmemoManager aTrack;
  final PubSubManager Function() pubsubOf;

  /// X25519 identity public key of one B-track device, taken from its
  /// bundle. Returns null when the device publishes no usable bundle.
  ///
  /// OMEMO2 classical IK is independent of the A-track / legacy IK
  /// (monocles stack separation).
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
  /// Capability ("are they on OMEMO2?") uses [fetchPqDeviceIds] alone —
  /// monocles does the same. Bundle fetch belongs only here, at encrypt time.
  Future<List<PqDevice>> loadPqDevices(JID jid) async {
    final listed = await fetchPqDeviceIds(jid);
    final out = <PqDevice>[];
    for (final id in listed.devices) {
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
      // monocles never-downgrade: refuse bundles without a verified v4
      // hybrid identity (pq-ik + pq-sig + ik-sig).
      if (!bundle.hasPqIdentity || !await verifyOmemo2Bundle(bundle)) {
        return null;
      }
      final pqId = parseOmemo2PqIdentity(bundle)!;
      final spk = base64Decode(bundle.spk);
      final signature = base64Decode(bundle.spkSignature);
      final ik = bundle.ikBytes;
      if (spk.length != 32 || ik.length != 32 || signature.length != 64) {
        return null;
      }

      // kem-spk is libsignal-tagged (0x0A ‖ pk).
      late final List<int> pqSpk;
      try {
        pqSpk = parseMlKem1024PublicKey(base64Decode(bundle.kemSpk));
      } catch (_) {
        return null;
      }

      final opks = <int, OmemoKeyPair>{};
      for (final e in bundle.prekeys.entries) {
        final bytes = base64Decode(e.value);
        if (bytes.length != 32) continue;
        opks[e.key] = OmemoKeyPair.fromBytes(
          bytes,
          List<int>.filled(32, 0),
          KeyPairType.x25519,
        );
      }
      final pqOpks = <int, Omemo2KyberPreKey>{};
      for (final e in bundle.kemPrekeys.entries) {
        try {
          final raw = parseMlKem1024PublicKey(base64Decode(e.value));
          final sigB64 = bundle.kemPrekeySignatures[e.key];
          if (sigB64 == null) continue;
          pqOpks[e.key] = Omemo2KyberPreKey(
            publicRaw: Uint8List.fromList(raw),
            secretRaw: Uint8List(MlKem1024.secretKeyLength),
            signature: Uint8List.fromList(base64Decode(sigB64)),
          );
        } catch (_) {
          continue;
        }
      }

      // Remote devices only need the X25519 public IK for DH; Ed25519
      // private is never published.
      final ikEdStub = OmemoKeyPair.fromBytes(
        List<int>.filled(32, 0),
        List<int>.filled(32, 0),
        KeyPairType.ed25519,
      );
      return Omemo2Device(
        jid: bundle.jid,
        id: bundle.deviceId,
        ikEd: ikEdStub,
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
        spkSignature: Uint8List.fromList(signature),
        pqSpk: Uint8List.fromList(pqSpk),
        pqSpkSecret: Uint8List(0),
        pqSpkId: bundle.kemSpkId,
        pqSpkSignature: Uint8List.fromList(
          base64Decode(bundle.kemSpkSignature),
        ),
        opks: opks,
        pqOpks: pqOpks,
        peerPqIdentityKey: pqId.pqIk,
        peerPqSignature: pqId.pqSig,
        peerIkSignature: pqId.ikSig,
      );
    } catch (_) {
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
    // `resolveOmemoDevices` already returns exactly this set: the ids whose
    // bundle actually fetched. This used to call `fetchOmemoDeviceIds`, which
    // throws that answer away and returns the raw list, and then fetch every
    // bundle again — serially. So the work the concurrency work had just
    // parallelised was discarded and redone one round-trip at a time, and the
    // result was the same set. `fetchOmemoDeviceIds` still exists for callers
    // that genuinely want the raw list.
    return (await resolveOmemoDevices(jid)).devices;
  }

  /// Raw device ids from [jid]'s OMEMO device list, whichever dialect it
  /// published — no bundle reachability filter.
  ///
  /// Matches Conversations' `IqParser.deviceIds`: the PEP list as advertised,
  /// including ids whose bundles we cannot fetch right now. Filtering those
  /// out before a merge-publish would drop live second devices from the list.
  ///
  /// Unions every dialect for *reads* (capability / encrypt). Own-list
  /// *publishes* must not use this union — see [publishOmemoBundle].
  Future<Set<int>> fetchOmemoDeviceIds(JID jid) async {
    final listed = <int>{};
    for (final node in [omemoDefactoDevicesNode, ...omemoSpecDevicesNodes]) {
      listed.addAll(await fetchOmemoDeviceIdsFromNode(jid, node));
    }
    return listed;
  }

  /// Device ids on one PEP dialect node only (Conversations reads a single
  /// node before `publishOwnDeviceId`).
  Future<Set<int>> fetchOmemoDeviceIdsFromNode(JID jid, String node) async {
    final pm = pubsubOf();
    final listed = <int>{};
    final items = await pm.getItems(jid, node);
    if (!items.isType<List<PubSubItem>>()) return listed;
    for (final item in items.get<List<PubSubItem>>()) {
      try {
        final doc = XmlDocument.parse(item.payload.toXml());
        final parsed = parseOmemoDeviceList(doc.rootElement);
        if (parsed != null) listed.addAll(parsed);
      } catch (_) {
        // Unreadable payload contributes nothing.
      }
    }
    return listed;
  }

  /// [jid]'s OMEMO devices whose bundle actually fetches, plus whether the
  /// device list itself could be read.
  ///
  /// The two answers must stay separate: "this contact publishes no
  /// devices" is a real, actionable answer, while "we could not read the
  /// list" means we know nothing and must not decide anything on that basis.
  Future<({Set<int> devices, bool listReadable})> resolveOmemoDevices(
    JID jid,
  ) async {
    try {
      return await _resolveOmemoDevices(jid);
    } on TimeoutException {
      // The caller can only act on one of the two answers, so "we could not
      // read it in time" has to be the same answer as "we could not read it".
      // Returning the ids we happened to collect instead would be the dangerous
      // version: a partial list looks exactly like a complete one, so every
      // device that had not answered yet would read as "this contact has no such
      // device", and the send would go out encrypted to a subset — which is the
      // failure this project refuses to have, arrived at from the other
      // direction.
      //
      // So a timeout yields "we know nothing", the track blocks, and the user is
      // told the truth rather than handed a message addressed to a guess.
      //
      // Logged, because this is the one path where the app refuses to send and
      // the UI can only say "we could not check": without a line here there is
      // no record anywhere of *why*, which makes it the hardest failure in this
      // app to read from outside.
      _log.warning(
        'device list for $jid did not finish within $kDeviceListDeadline; '
        'treating it as unreadable, which blocks sending',
      );
      return (devices: const <int>{}, listReadable: false);
    }
  }

  Future<({Set<int> devices, bool listReadable})> _resolveOmemoDevices(
    JID jid,
  ) {
    // The deadline is on the whole resolution, list reads included. Generous
    // enough that a slow server on a large account still answers, and short
    // enough that "Connecting…" is never what the user is looking at.
    return _resolveOmemoDevicesUnbounded(jid).timeout(kDeviceListDeadline);
  }

  Future<({Set<int> devices, bool listReadable})> _resolveOmemoDevicesUnbounded(
    JID jid,
  ) async {
    final pm = pubsubOf();
    final listed = <int>{};
    var listReadable = false;
    final started = DateTime.now();
    for (final node in [omemoDefactoDevicesNode, ...omemoSpecDevicesNodes]) {
      final items = await pm.getItems(jid, node);
      if (!items.isType<List<PubSubItem>>()) continue;
      for (final item in items.get<List<PubSubItem>>()) {
        try {
          final doc = XmlDocument.parse(item.payload.toXml());
          final parsed = parseOmemoDeviceList(doc.rootElement);
          if (parsed == null) continue;
          listReadable = true;
          listed.addAll(parsed);
        } catch (_) {
          // A payload we cannot read simply contributes nothing.
        }
      }
    }
    if (!listReadable) return (devices: const <int>{}, listReadable: false);

    // Both numbers, because the deadline above is a budget for the sweep and
    // the sweep is the only part whose cost grows with the contact's history.
    // "30 devices, 22 bundles" and "30 devices, 0 bundles" are the same
    // `reliable` value and completely different situations.
    _log.fine('$jid publishes ${listed.length} OMEMO device ids');

    // One round-trip per device, and *concurrently* rather than one after
    // another.
    //
    // The sequential version cost one network wait per published device id. A
    // contact whose account has accumulated forty of them — which is what a test
    // account does, and what any account does across years of reinstalls — took
    // around seventy seconds to resolve, and because the chat page resolves on
    // every rebuild the cost was re-paid continuously rather than once. That is
    // the whole of the "Connecting…" that looks like a hang, and of the idle
    // one-request-per-second trickle seen with nothing happening on screen.
    //
    // Bounded rather than unbounded: forty simultaneous IQs is its own kind of
    // bad manners, and a contact with four hundred devices would otherwise open
    // four hundred. The cap is high enough that a normal account finishes in one
    // round-trip's time and low enough to stay a polite client.
    final devices = <int>{};
    await forEachBounded(listed, kBundleFetchConcurrency, (id) async {
      if (await getOmemoBundle(jid, id) != null) devices.add(id);
    });
    _log.fine(
      '$jid: ${devices.length} of ${listed.length} device bundles usable, '
      'took ${DateTime.now().difference(started).inMilliseconds}ms '
      '(budget ${kDeviceListDeadline.inSeconds}s)',
    );
    return (devices: devices, listReadable: true);
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
  // ── Per-stack publish history (A and B are independent) ──────────────
  //
  // Not secret — these ids are on a public node — and deliberately separate
  // from the sealed key material: a user who clears their keys should still
  // have the previous ids remembered, because that is exactly the case where
  // the next merge must not put them back on the list.

  /// Classic OMEMO (A-track) ids this installation has published.
  PublishedDeviceMemory? omemoDeviceMemory;

  /// OMEMO2 / PQ (B-track) ids this installation has published.
  PublishedDeviceMemory? pqDeviceMemory;

  Future<Set<int>> publishedOmemoDeviceIds() =>
      _publishedIds(_omemoPublished, omemoDeviceMemory);

  Future<Set<int>> publishedPqDeviceIds() =>
      _publishedIds(_pqPublished, pqDeviceMemory);

  Future<void> notePublishedOmemoDevice(int id) =>
      _notePublished(id, _omemoPublished, omemoDeviceMemory);

  Future<void> notePublishedPqDevice(int id) =>
      _notePublished(id, _pqPublished, pqDeviceMemory);

  /// Wipe / regenerate: local history must match the singleton PEP list.
  Future<void> replacePublishedOmemoDevices(Set<int> ids) =>
      _replacePublished(ids, _omemoPublished, omemoDeviceMemory);

  Future<void> replacePublishedPqDevices(Set<int> ids) =>
      _replacePublished(ids, _pqPublished, pqDeviceMemory);

  final _omemoPublished = <int>{};
  final _pqPublished = <int>{};

  Future<Set<int>> _publishedIds(
    Set<int> memory,
    PublishedDeviceMemory? store,
  ) async {
    final loader = store?.load;
    if (loader == null) return memory;
    final stored = await loader();
    return {...memory, ...stored};
  }

  Future<void> _notePublished(
    int id,
    Set<int> memory,
    PublishedDeviceMemory? store,
  ) async {
    memory.add(id);
    await store?.save({...memory});
  }

  Future<void> _replacePublished(
    Set<int> ids,
    Set<int> memory,
    PublishedDeviceMemory? store,
  ) async {
    memory
      ..clear()
      ..addAll(ids);
    await store?.save({...memory});
  }

  Future<AxolotlBundle?> getOmemoBundle(JID jid, int deviceId) async {
    final pm = pubsubOf();
    final nodes = [
      '$omemoDefactoBundlesNode:$deviceId',
      for (final n in omemoSpecBundlesNodes) '$n:$deviceId',
    ];
    for (final node in nodes) {
      final items = await pm.getItems(jid, node);
      if (!items.isType<List<PubSubItem>>()) continue;
      for (final item in items.get<List<PubSubItem>>()) {
        final AxolotlBundle bundle;
        try {
          final doc = XmlDocument.parse(item.payload.toXml());
          bundle = parseOmemoBundle(
            doc.rootElement,
            jid: jid.toBare().toString(),
            deviceId: deviceId,
          );
        } catch (_) {
          // Try the next item, then the next dialect.
          continue;
        }
        // Parsing is not reachability.
        //
        // An account accumulates devices — reinstalls, test runs, a signed
        // prekey rotated out from under its own signature — and every bundle
        // that no longer verifies is a device *no* client can open a session
        // with. Offering one to the session builder does not merely lose that
        // device: the failure is recorded as an error against the recipient,
        // and an error against the recipient cancels the send as a whole
        // (`canSendAllDevicesReached`). One dead entry is therefore enough to
        // make the contact unmessageable, which is exactly what the 33 dead
        // entries on the peer account did. Conversations skips such a device
        // and delivers to the rest; so do we.
        if (!omemoBundleUsable(bundle)) {
          _log.fine(
            '$jid:$deviceId: bundle on $node does not verify, '
            'skipping device',
          );
          continue;
        }
        return bundle;
      }
    }
    return null;
  }

  /// Publishes [ids] as our OMEMO device list in both dialects.
  ///
  /// Conversations' `publishDeviceIdsAndRefineAccessModel`: the caller decides
  /// whether [ids] is a merge (`publishOwnDeviceId`) or a wipe
  /// (`wipeOtherPepDevices` = singleton of our id).
  Future<bool> publishOmemoDeviceIds(JID bareJid, Set<int> ids) async {
    final pm = pubsubOf();
    var listOk = false;
    for (final node in [omemoDefactoDevicesNode, ...omemoSpecDevicesNodes]) {
      final listResult = await pm.publish(
        bareJid,
        node,
        XMLNode.fromString(deviceListToDefactoXml(ids).toXmlString()),
        id: 'current',
        options: const PubSubPublishOptions(accessModel: 'open'),
      );
      if (listResult.isType<bool>() && listResult.get<bool>()) listOk = true;
      try {
        await pm.configure(
          bareJid,
          node,
          const PubSubPublishOptions(accessModel: 'open'),
        );
      } catch (_) {
        // Best-effort access-model tighten.
      }
    }
    return listOk;
  }

  /// Conversations `publishBundlesIfNeeded` then `publishOwnDeviceIdIfNeeded`.
  ///
  /// Order matches Conversations: publish the bundle(s) first; only after a
  /// successful bundle write do we announce our device id. Each device-list
  /// node is retrieved and rewritten on its own (never a cross-dialect
  /// union — that resurrects ids a wipe already cleared on one node).
  ///
  /// Spec bundles are written directly. We do **not** call moxxmpp
  /// [OmemoManager.publishBundle]: that path retrieves and rewrites the
  /// device list a second time, undoing the per-node merge above.
  Future<bool> publishOmemoBundle(JID bareJid, AxolotlBundle bundle) async {
    final pm = pubsubOf();
    final ourId = bundle.deviceId;

    final defactoBundle = await pm.publish(
      bareJid,
      '$omemoDefactoBundlesNode:$ourId',
      XMLNode.fromString(bundleToDefactoXml(bundle).toXmlString()),
      id: 'current',
      options: const PubSubPublishOptions(accessModel: 'open', maxItems: '1'),
    );
    final defactoOk = defactoBundle.isType<bool>() && defactoBundle.get<bool>();
    try {
      await pm.configure(
        bareJid,
        '$omemoDefactoBundlesNode:$ourId',
        const PubSubPublishOptions(accessModel: 'open'),
      );
    } catch (_) {
      // Best-effort access-model tighten.
    }

    var specOk = false;
    for (final node in omemoSpecBundlesNodes) {
      final specBundle = await pm.publish(
        bareJid,
        node,
        axolotlBundleToXML(bundle),
        id: '$ourId',
        options: const PubSubPublishOptions(
          accessModel: 'open',
          maxItems: 'max',
        ),
      );
      if (specBundle.isType<bool>() && specBundle.get<bool>()) specOk = true;
      try {
        await pm.configure(
          bareJid,
          node,
          const PubSubPublishOptions(accessModel: 'open', maxItems: 'max'),
        );
      } catch (_) {
        // Best-effort access-model tighten.
      }
    }

    // Conversations only announces after the bundle is current on PEP.
    if (!defactoOk && !specOk) return false;

    final ours = await publishedOmemoDeviceIds();
    var listOk = false;
    for (final node in [omemoDefactoDevicesNode, ...omemoSpecDevicesNodes]) {
      // Conversations: retrieveDeviceIds → publishOwnDeviceId(pepList + own).
      final ids = await fetchOmemoDeviceIdsFromNode(bareJid, node);
      // Ids this install previously published are superseded builds. Leaving
      // them in the merge re-announces a wipe. Live second phones are never
      // in [publishedOmemoDeviceIds], so they remain.
      ids.removeWhere((id) => id != ourId && ours.contains(id));
      ids.add(ourId);
      final listResult = await pm.publish(
        bareJid,
        node,
        XMLNode.fromString(deviceListToDefactoXml(ids).toXmlString()),
        id: 'current',
        options: const PubSubPublishOptions(accessModel: 'open'),
      );
      if (listResult.isType<bool>() && listResult.get<bool>()) listOk = true;
      try {
        await pm.configure(
          bareJid,
          node,
          const PubSubPublishOptions(accessModel: 'open'),
        );
      } catch (_) {
        // Best-effort access-model tighten.
      }
    }

    return listOk;
  }

  /// Publishes [ids] as our OMEMO2 / PQ device list (B-track PEP only).
  ///
  /// Parallel to [publishOmemoDeviceIds]. Caller chooses merge vs wipe
  /// (singleton of our id).
  Future<bool> publishPqDeviceIds(JID bareJid, Set<int> ids) async {
    final pm = pubsubOf();
    final listResult = await pm.publish(
      bareJid,
      omemo2DevicesXmlns,
      XMLNode.xmlns(
        tag: 'devices',
        xmlns: omemo2Xmlns,
        children: [
          for (final id in ids)
            XMLNode(tag: 'device', attributes: {'id': '$id'}),
        ],
      ),
      id: 'current',
      options: const PubSubPublishOptions(accessModel: 'open'),
    );
    if (!listResult.isType<bool>() || !listResult.get<bool>()) return false;
    try {
      await pm.configure(
        bareJid,
        omemo2DevicesXmlns,
        const PubSubPublishOptions(accessModel: 'open'),
      );
    } catch (_) {
      // Best-effort access-model tighten.
    }
    return true;
  }

  /// Publishes our OMEMO2 / PQ bundle, then announces our device id.
  ///
  /// Parallel to [publishOmemoBundle]: same order (bundle → device list),
  /// same merge rules, independent PEP namespace ([omemo2BundlesXmlns] /
  /// [omemo2DevicesXmlns]). Does not touch classic OMEMO nodes or
  /// [publishedOmemoDeviceIds].
  Future<bool> publishPqBundle(JID bareJid, PqBundle bundle) async {
    final pm = pubsubOf();
    final ourId = bundle.deviceId;

    final bundleResult = await pm.publish(
      bareJid,
      omemo2BundlesXmlns,
      XMLNode.fromString(bundle.toXml().toXmlString()),
      id: '$ourId',
      options: const PubSubPublishOptions(accessModel: 'open', maxItems: 'max'),
    );
    if (!bundleResult.isType<bool>() || !bundleResult.get<bool>()) {
      return false;
    }
    try {
      await pm.configure(
        bareJid,
        omemo2BundlesXmlns,
        const PubSubPublishOptions(accessModel: 'open', maxItems: 'max'),
      );
    } catch (_) {
      // Best-effort access-model tighten.
    }

    // Same merge as classic announce, on the B list/history only.
    final ours = await publishedPqDeviceIds();
    final ids = (await fetchPqDeviceIds(bareJid)).devices;
    ids.removeWhere((id) => id != ourId && ours.contains(id));
    ids.add(ourId);
    return publishPqDeviceIds(bareJid, ids);
  }

  /// OMEMO2 device ids published on the B-track PEP node — list only.
  ///
  /// Matches monocles `omemo2DeviceIds`: a non-empty list means the contact
  /// is on OMEMO2. Bundle reachability is checked later at encrypt time
  /// ([loadPqDevices]), never folded into this answer and never intersected
  /// with the classic axolotl device list.
  Future<({Set<int> devices, bool listReadable})> fetchPqDeviceIds(
    JID jid,
  ) async {
    final pm = pubsubOf();
    final items = await pm.getItems(jid, omemo2DevicesXmlns);
    if (!items.isType<List<PubSubItem>>()) {
      return (devices: <int>{}, listReadable: false);
    }
    final ids = <int>{};
    for (final item in items.get<List<PubSubItem>>()) {
      for (final dev in item.payload.children.where((c) => c.tag == 'device')) {
        final id = int.tryParse('${dev.attributes['id']}');
        if (id != null) ids.add(id);
      }
    }
    return (devices: ids, listReadable: true);
  }

  /// @Deprecated Prefer [fetchPqDeviceIds] — kept as the raw id set for
  /// callers that already treat "listed on OMEMO2" as capability.
  Future<Set<int>> getPqCapableDevices(JID jid) async =>
      (await fetchPqDeviceIds(jid)).devices;

  /// Fetches one device's B-track bundle, or null when absent/broken.
  /// Malformed payloads never throw: they just mean "not encryptable yet".
  Future<PqBundle?> getPqBundle(JID jid, int deviceId) async {
    final pm = pubsubOf();
    final res = await pm.getItem(jid, omemo2BundlesXmlns, '$deviceId');
    if (!res.isType<PubSubItem>()) return null;
    try {
      final doc = XmlDocument.parse(res.get<PubSubItem>().payload.toXml());
      // PEP item id is the device id — the payload historically omitted it,
      // which made every fetched peer look like device 0 and decrypt fail.
      final bundle = PqBundle.fromXml(
        doc.rootElement,
        jidOfBundle: jid.toBare().toString(),
        deviceId: deviceId,
      );
      // monocles IqParser + PqBundle.verify: refuse incomplete / bad signatures
      // so we never encrypt to or display a half-published device.
      final reason = await omemo2BundleRefusal(bundle);
      if (reason != null) {
        _log.warning('PQ bundle for $jid:$deviceId refused: $reason');
        return null;
      }
      return bundle;
    } catch (e, st) {
      _log.warning('PQ bundle parse failed for $jid:$deviceId: $e\n$st');
      return null;
    }
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
    // Concurrent across owners for the same reason: each call is itself a
    // fan-out, and serialising the owners makes the total a sum of them.
    await forEachBounded(byOwner.entries, kBundleFetchConcurrency, (
      entry,
    ) async {
      final listed = await fetchPqDeviceIds(JID.fromString(entry.key));
      pqCapable.addAll(listed.devices);
    });
    // No ∩ with [allDevices]: B-track ids are independent of the classic set
    // (monocles keeps separate maps). decideEncMode ignores extras.
    return decideEncMode(
      allDevices: allDevices,
      pqCapable: pqCapable,
      omemoCapable: omemoCapable,
    );
  }
}

/// Where the set of published device ids is kept across restarts.
class PublishedDeviceMemory {
  const PublishedDeviceMemory({required this.load, required this.save});

  final Future<Set<int>> Function() load;
  final Future<void> Function(Set<int>) save;
}
