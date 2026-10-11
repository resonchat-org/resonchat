// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Dual-track manager: A track (standard OMEMO via moxxmpp) plus B track
// (PQ-OMEMO via our own PEP nodes). See docs/02 and docs/03.

import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:logging/logging.dart';
import 'package:moxxmpp/moxxmpp.dart';
import 'package:omemo_dart/omemo_dart.dart' hide OmemoManager;
import 'package:omemo_dart/omemo_dart_axolotl.dart' show AxolotlBundle;
import 'package:xml/xml.dart';

import '../pq/mlkem.dart';
import 'bounded.dart';
import 'bundle_codec.dart';
import 'defacto.dart';
import 'negotiation.dart';
import 'pq_session.dart';
import 'protocol.dart';
import 'device_pruning.dart';

/// [ids] as an ascending, comma-separated string.
///
/// Sorted because this goes into a log line that someone will read twice and
/// compare against a server response by eye; set iteration order makes two
/// identical accounts print two different lines, which is indistinguishable from
/// a real difference.
String sortedNumericIds(Iterable<int> ids) {
  final sorted = ids.toList()..sort();
  return sorted.isEmpty ? '(none)' : sorted.join(',');
}

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

/// Owns the B track's PEP state and the outbound-track decision.
///
/// The A track is fully delegated to moxxmpp's [OmemoManager] (kept
/// byte-compatible with Conversations/Moxxy/Dino); the B track uses
/// parallel PEP nodes ([pomemoDevicesXmlns]/[pomemoBundlesXmlns]) so
/// standard clients never see keys they cannot use.
class DualTrackManager {
  DualTrackManager({required this.aTrack, required this.pubsubOf});

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
  /// published.
  Future<Set<int>> fetchOmemoDeviceIds(JID jid) async =>
      (await resolveOmemoDevices(jid)).devices;

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
  /// Note the item id: real clients publish the bundle under the item
  /// `current`, while moxxmpp uses the device id. Asking for one specific
  /// id and failing on the other would make every peer look incapable, so
  /// the whole node is fetched and whichever item parses is taken.
  /// Persistence for the set of device ids this installation has published.
  ///
  /// Not secret — these ids are on a public node — and deliberately separate
  /// from the sealed key material: a user who clears their keys should still
  /// have the previous ids remembered, because that is exactly the case where
  /// pruning them matters.
  PublishedDeviceMemory? deviceMemory;

  /// Every device id this installation has published, newest last.
  Future<Set<int>> publishedDeviceIds() async {
    final loader = deviceMemory?.load;
    if (loader == null) return _published;
    final stored = await loader();
    // Union rather than replace: the in-memory set may already hold an id
    // published a moment ago and not yet flushed.
    return {..._published, ...stored};
  }

  /// Records [id] as published, both in memory and in the store.
  Future<void> notePublishedDevice(int id) async {
    _published.add(id);
    await deviceMemory?.save({..._published});
  }

  final _published = <int>{};

  /// Whether [deviceId]'s bundle is **known to be absent**.
  ///
  /// The distinction is the whole point, and it is why the pubsub layer had to
  /// learn the error conditions: a node that does not exist and a node we
  /// failed to read both used to come back as `UnknownPubSubError`, and a
  /// signal that cannot tell them apart cannot answer this question. It now
  /// returns `item-not-found` / `node-not-found` as themselves, and only those
  /// count as absence.
  ///
  /// Both the de-facto and the spec dialect are consulted: a peer may have
  /// published a bundle in either, and "not in the first one" is not "gone"
  /// until the second has been asked too.
  Future<bool> bundleKnownAbsent(JID jid, int deviceId) async {
    final pm = pubsubOf();
    for (final node in [
      '$omemoDefactoBundlesNode:$deviceId',
      for (final n in omemoSpecBundlesNodes) '$n:$deviceId',
    ]) {
      final items = await pm.getItems(jid, node);
      if (items.isType<List<PubSubItem>>()) {
        for (final item in items.get<List<PubSubItem>>()) {
          try {
            final doc = XmlDocument.parse(item.payload.toXml());
            parseOmemoBundle(
              doc.rootElement,
              jid: jid.toBare().toString(),
              deviceId: deviceId,
            );
            // Present and usable.
            return false;
          } catch (_) {
            // Present but unparseable. Not absence: removing it would remove a
            // device that is really there.
            return false;
          }
        }
        // The node answered with nothing.
        return true;
      }
      if (!pubSubErrorMeansAbsent(items.get<PubSubError>())) {
        // We do not know, and "we do not know" is not permission to remove a
        // device. Try the other dialect rather than concluding anything.
        continue;
      }
      // This dialect positively says the item is not there. The other dialect
      // might still have it, so keep going and only conclude once every node
      // has said so.
    }
    // Every dialect said "not there", or said it for the one that exists.
    return true;
  }

  /// Removes device ids from [bareJid]'s own published list whose bundle is
  /// known to be gone.
  ///
  /// Only ever called for a JID we publish to ourselves, and only removes ids
  /// that have been *positively* established as dead. Never touches a peer's
  /// list: we have no rights there, and a client that pruned somebody else's
  /// device list would be silently downgrading them.
  ///
  /// Returns the ids removed, so the caller can say what happened.
  Future<Set<int>> pruneOwnDeadDevices(JID bareJid, int ourDeviceId) async {
    final pm = pubsubOf();
    final listed = await fetchOmemoDeviceIds(bareJid);
    if (listed.isEmpty) return const {};

    // One round trip per id, fetched up front so the decision below is pure
    // arithmetic on answers we already have.
    final absent = <int, bool>{};
    for (final id in listed) {
      if (id == ourDeviceId) continue;
      absent[id] = await bundleKnownAbsent(bareJid, id);
    }

    // The case `bundleKnownAbsent` structurally cannot see.
    //
    // Its question is "does this bundle exist on the server", and a bundle can
    // exist for a device whose **private keys exist nowhere**: the keys live
    // only in this app's sealed store, so wiping the app's data destroys them
    // while leaving the published bundle exactly where it was. Such a device
    // passes the absent test, is kept, and every message encrypted to it is
    // then read by nobody — permanently, silently, with no error anywhere. A
    // peer does not report a decryption failure for it; it reports a *send*
    // failure, because a client that finds an unusable device may refuse to
    // send at all, which is what Conversations reported.
    //
    // `publishedDeviceIds` is what makes this decidable rather than a guess. It
    // is the record of the ids **this installation** created, and it is empty
    // on a fresh install precisely because the sealed store was destroyed along
    // with the keys. So when that record holds nothing but our current id, every
    // other id on the list was made by an installation whose keys we do not
    // have — not "might have", *do not*. Retracting those loses nothing,
    // because nobody was ever going to read those messages.
    //
    // The condition is deliberately narrow. A second, *live* device of the same
    // account has its id in this record too, so its ids are never touched here;
    // this only fires on a fresh install, which is the one situation where the
    // record is provably incomplete. The rule this project follows everywhere —
    // never remove a device we cannot prove is dead — is why the case is
    // expressed as "we can prove we hold no keys for this" rather than as "this
    // bundle looks stale".
    final ours = await publishedDeviceIds();
    final onlyOurs = ours.isEmpty || ours.length <= 1;
    if (onlyOurs) {
      for (final id in listed) {
        if (id == ourDeviceId) continue;
        absent[id] = true;
      }
    }

    // The decision is now made, so say what it was made from.
    //
    // Without this the whole prune is unobservable: it keeps a device or drops
    // it silently, and "our device list advertises an id whose bundle is gone"
    // — the state that makes a peer report "could not fetch encryption keys"
    // and then encrypt to a device nobody holds keys for — looks exactly like a
    // healthy account from inside this app. An id is only ever *absent* from
    // `absent` when it is our own current device, so this line is the complete
    // list of what the account is claiming and why.
    final claimed = listed.where(
      (id) => id == ourDeviceId || absent[id] != true,
    );
    _log.fine(
      'own device list for ${bareJid.toBare().toString()}: '
      'claiming ${sortedNumericIds(claimed)} of ${sortedNumericIds(listed)}'
      ' (ourDeviceId=$ourDeviceId); bundle absent for '
      '${sortedNumericIds(absent.entries.where((e) => e.value).map((e) => e.key))}',
    );

    final kept = keepableDeviceIds(
      listed: listed,
      ourDeviceId: ourDeviceId,
      bundleAbsent: (id) => absent[id] ?? false,
    );
    final dead = deadDeviceIds(listed: listed, kept: kept);
    if (dead.isEmpty) return const {};

    // Both dialects: a client reading either one must not see the dead ids.
    for (final node in [omemoDefactoDevicesNode, ...omemoSpecDevicesNodes]) {
      await pm.publish(
        bareJid,
        node,
        XMLNode.fromString(deviceListToDefactoXml(kept).toXmlString()),
        id: 'current',
        options: const PubSubPublishOptions(accessModel: 'open'),
      );
    }
    return dead;
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
  Future<bool> publishOmemoBundle(JID bareJid, AxolotlBundle bundle) async {
    final pm = pubsubOf();

    // Publish *only* the device we can actually service. See prior comments:
    // re-publishing the server's full list grows phantom device ids.
    final ids = <int>{bundle.deviceId};

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
      '$omemoDefactoBundlesNode:${bundle.deviceId}',
      XMLNode.fromString(bundleToDefactoXml(bundle).toXmlString()),
      id: 'current',
      options: const PubSubPublishOptions(accessModel: 'open', maxItems: '1'),
    );
    final bundleOk = bundleResult.isType<bool>() && bundleResult.get<bool>();

    for (final node in <String>[
      omemoDefactoDevicesNode,
      '$omemoDefactoBundlesNode:${bundle.deviceId}',
    ]) {
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

    // Spec dialect via moxxmpp (bool true == failure).
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
    final ids = <int>{};
    for (final item in items.get<List<PubSubItem>>()) {
      for (final dev in item.payload.children.where((c) => c.tag == 'device')) {
        final id = int.tryParse('${dev.attributes['id']}');
        if (id == null) continue;
        ids.add(id);
      }
    }
    // Concurrent for the same reason as the standard track's list, and it sits
    // on the same capability path: `_resolve` calls this right after
    // `resolveOmemoDevices`, so a serial loop here made the total cost of one
    // capability lookup *twice* what the concurrency work had just reduced it to.
    await forEachBounded(ids, kBundleFetchConcurrency, (id) async {
      final bundle = await getPqBundle(jid, id);
      if (bundle != null && bundle.hasPqKeys) result.add(id);
    });
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
      return PqBundle.fromXml(
        doc.rootElement,
        jidOfBundle: jid.toBare().toString(),
      );
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
        for (final dev in item.payload.children.where(
          (c) => c.tag == 'device',
        )) {
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
        for (final id in ids) XMLNode(tag: 'device', attributes: {'id': '$id'}),
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

    final bundleNode = XMLNode.fromString(bundle.toXml().toXmlString());
    final bundleResult = await pm.publish(
      bareJid,
      pomemoBundlesXmlns,
      bundleNode,
      id: '${bundle.deviceId}',
      options: const PubSubPublishOptions(accessModel: 'open', maxItems: 'max'),
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
    // Concurrent across owners for the same reason: each call is itself a
    // fan-out, and serialising the owners makes the total a sum of them.
    await forEachBounded(byOwner.entries, kBundleFetchConcurrency, (
      entry,
    ) async {
      pqCapable.addAll(await getPqCapableDevices(JID.fromString(entry.key)));
    });
    return decideEncMode(
      allDevices: allDevices,
      pqCapable: pqCapable.intersection(allDevices),
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
