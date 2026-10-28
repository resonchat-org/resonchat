// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Owns the local B-track (PQ-OMEMO) device and wires it into the message
// path: publish our bundle, encrypt on the B track when the chat qualifies,
// and decrypt inbound PQ messages.
//
// The A track keeps going through moxxmpp untouched, so standard clients
// stay interoperable.

import 'dart:convert';
import 'dart:math';

import 'package:logging/logging.dart';
import 'package:moxxmpp/moxxmpp.dart';
import 'package:omemo_dart/omemo_dart_omemo2.dart';

import 'package:resonchat/crypto/dual/dual_track_manager.dart';
import 'package:resonchat/crypto/dual/fingerprint_trust.dart';
import 'package:resonchat/crypto/dual/pq_device_list_snapshot.dart';
import 'package:resonchat/crypto/omemo2/bundle_codec.dart';
import 'package:resonchat/crypto/omemo2/message_codec.dart';
import 'package:resonchat/crypto/omemo2/pq_message_layer.dart';
import 'package:resonchat/crypto/omemo2/pq_peer_resolver.dart';
import 'package:resonchat/crypto/omemo2/pq_session.dart';
import 'package:resonchat/persistence/omemo2_device_store.dart';
import 'package:resonchat/persistence/omemo2_pq_pin_store.dart';
import 'package:resonchat/persistence/pq_identity_store.dart';
import 'package:resonchat/xmpp/encryption/capabilities.dart';

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
    required this.accountId,
    required this.pqIdentity,
    required this.deviceStore,
    this.fingerprintTrust,
    this.pqPins,
  });

  final Logger _log = Logger('BTrackManager');
  final DualTrackManager Function() tracks;
  final PubSubManager? Function() pubsubOf;
  final String accountId;

  /// Shared with [OmemoDeviceStore.pqIdentity] so UI and publish use one ML-DSA key.
  final PqIdentityStore pqIdentity;

  final Omemo2DeviceStore deviceStore;

  /// When set, skip devices whose fingerprint the user marked untrusted.
  final FingerprintTrustStore? fingerprintTrust;

  /// Never-overwrite `<pq-ik>` pins (monocles OMEMO2 PQ identities table).
  final Omemo2PqPinStore? pqPins;

  BTrackSession? _session;
  PqPeerResolver? _resolver;
  CapabilityService? _capabilities;

  /// Our B-track device once it exists.
  PqDevice? get device => _session?.device;

  bool get ready => _session != null;

  /// The single device-list owner is wired after the XmppService exists.
  ///
  /// The resolver is created with a callback, so attaching later still routes
  /// every lookup through this CapabilityService.
  void attachCapabilities(CapabilityService capabilities) {
    _capabilities = capabilities;
  }

  /// PEP told us this peer changed. The resolver must forget its fingerprint
  /// and announced-view caches before the next send.
  void invalidatePeer(JID jid) => _resolver?.invalidate(jid);

  Future<PqDeviceListSnapshot> _snapshotFor(JID jid) {
    final capabilities = _capabilities;
    if (capabilities == null) {
      throw StateError('CapabilityService is not attached to BTrackManager');
    }
    return capabilities.pqSnapshotFor(jid);
  }

  /// Creates (or restores) the local B-track device and publishes it.
  ///
  /// Called after connect; safe to call again to refresh the bundle.
  ///
  /// [classicDeviceId] — when provided, reused as the OMEMO2 registration id
  /// (monocles `getOwnDeviceId()` on both stacks). Keys remain independent.
  Future<bool> initialise(
    String bareJid, {
    int opkCount = 20,
    int pqCount = 5,
    int? classicDeviceId,
    bool forceNew = false,
  }) async {
    final pm = pubsubOf();
    if (pm == null) {
      _log.warning('no PubSub manager; B track unavailable');
      return false;
    }

    Omemo2Device? device;
    if (!forceNew) {
      device = await deviceStore.load();
      if (device != null && device.jid != bareJid) {
        _log.warning('OMEMO2 device jid mismatch; regenerating');
        device = null;
      }
    }
    if (device == null) {
      device = await PqDevice.generate(
        bareJid,
        opkCount: opkCount,
        pqOpkCount: pqCount,
        deviceId: classicDeviceId,
      );
      await deviceStore.save(device);
    }
    await device.ensureStores();
    // Ensure ML-DSA-87 identity exists before first publish.
    await pqIdentity.publicKey();
    final sessions = PqSessionManager(onCommit: deviceStore.save);
    // The resolver calls hasSession before it asks for bundles. Bind here so
    // a restored session is visible before the first send (docs/11 §5.2).
    await sessions.bindOwn(device);
    final layer = PqMessageLayer(
      ownDevice: device,
      sessions: sessions,
      pqIdentity: pqIdentity,
      pins: pqPins,
    );
    _resolver = PqPeerResolver(
      tracks: tracks,
      sessions: sessions,
      snapshotFor: _snapshotFor,
      fingerprintTrust: fingerprintTrust,
      pqPins: pqPins,
    );
    _session = BTrackSession(device: device, sessions: sessions, layer: layer);

    // Top up local KEM OPKs first (no PEP write), then reconcile — monocles
    // publishBundlesIfNeeded / verifyOmemo2 path, OMEMO2 node only.
    await replenishPrekeys(target: pqCount, republish: false);
    final minKem = pqCount <= 1 ? pqCount : pqCount ~/ 2;
    final published = await publish(
      force: forceNew,
      minKemPreKeys: minKem < 1 ? 1 : minKem,
    );
    _log.info(
      published
          ? (forceNew
                ? 'PQ bundle published'
                : 'PQ bundle publish-if-needed done')
          : 'PQ bundle publish failed',
    );
    return published;
  }

  /// Drop local OMEMO2 identity and mint a new one (monocles OMEMO2 regenerate).
  Future<bool> regenerate({
    required String bareJid,
    int? classicDeviceId,
    bool wipeOther = false,
  }) async {
    _session = null;
    await deviceStore.clear();
    await pqIdentity.clear();
    final ok = await initialise(
      bareJid,
      classicDeviceId: classicDeviceId,
      forceNew: true,
    );
    if (ok && wipeOther) {
      await wipeOtherDevices();
    }
    return ok;
  }

  /// Wipe other devices from the B-track PEP list only.
  ///
  /// Parallel to [XmppConnection.wipeOtherOmemoDevices]: PEP write lives in
  /// [DualTrackManager.publishPqDeviceIds], history reset is B-only.
  Future<bool> wipeOtherDevices() async {
    final session = _session;
    if (session == null) return false;
    final bare = JID.fromString(session.device.jid);
    final id = session.device.id;
    final ok = await tracks().publishPqDeviceIds(bare, {id});
    if (ok) await tracks().replacePublishedPqDevices({id});
    return ok;
  }

  /// Publishes our B-track bundle via [DualTrackManager.publishPqBundleIfNeeded].
  ///
  /// Parallel to [XmppConnection.ensureOmemoDevice] → classic if-needed:
  /// this manager owns the session; PEP I/O lives on DualTrackManager.
  /// Never touches classic OMEMO nodes.
  Future<bool> publish({bool force = false, int minKemPreKeys = 3}) async {
    final session = _session;
    if (session == null) return false;
    final bundle = await _toBundle(session.device);
    final bare = JID.fromString(session.device.jid);
    return tracks().publishPqBundleIfNeeded(
      bare,
      bundle,
      force: force,
      minKemPreKeys: minKemPreKeys,
    );
  }

  /// Encrypts [plaintext] for every PQ-capable device of [peerJid].
  ///
  /// Returns null when the peer has no PQ devices or nothing could be
  /// encrypted; the caller must then fall back to the A track rather than
  /// send something unreadable.
  Future<PqEncryptedMessage?> encryptIfPossible({
    required String peerJid,
    required String plaintext,
  }) => encryptForPeers(peerJids: [peerJid], plaintext: plaintext);

  /// Encrypts [plaintext] for every PQ device of each bare JID in [peerJids]
  /// (1:1 peer, or MUC member real JIDs + our own bare for multi-device).
  ///
  /// One payload, keys per device — same layout as a 1:1 PQ message.
  Future<PqEncryptedMessage?> encryptForPeers({
    required List<String> peerJids,
    required String plaintext,
  }) async {
    final session = _session;
    final resolver = _resolver;
    if (session == null || resolver == null) return null;

    final requested = <String>[];
    final seen = <String>{};
    for (final jid in peerJids) {
      final bare = JID.fromString(jid).toBare().toString();
      if (seen.add(bare)) requested.add(bare);
    }
    if (requested.isEmpty) return null;

    final resolution = await resolver.resolve(requestedJids: requested);
    if (resolution.blocked) {
      _log.warning(
        'PQ send blocked: ${resolution.blockedReason!.name} '
        'at ${resolution.blockedJid ?? '-'}'
        '${resolution.blockedDeviceId == null ? '' : '/${resolution.blockedDeviceId}'}',
      );
      return null;
    }
    if (resolution.actualJids.isEmpty) {
      _log.warning('PQ send has no actual encryption targets');
      return null;
    }
    if (resolution.excluded.isNotEmpty) {
      _log.info('PQ send excludes untrusted devices: ${resolution.excluded}');
    }

    final outgoing = await session.layer.encrypt(
      plaintext: plaintext,
      requestedJids: resolution.requestedJids,
      announcedDeviceIds: resolution.announcedDeviceIds,
      recipientDeviceIds: resolution.allowedDeviceIds,
      recipients: resolution.newDevices,
    );
    return outgoing?.stanza;
  }

  /// Decrypts an inbound PQ message; null when it is not for us (a different
  /// device, or not a B-track message at all).
  ///
  /// [senderBareJid] is the peer bare JID (groupchat: occupant real JID).
  Future<String?> decryptIfPossible(
    PqEncryptedMessage message, {
    required String senderBareJid,
  }) async {
    final session = _session;
    if (session == null) return null;

    if (!message.keys.any((k) => k.recipientDeviceId == session.device.id)) {
      return null;
    }
    return session.layer.decrypt(message, senderBareJid: senderBareJid);
  }

  /// Refills the ML-KEM one-time prekey pool back up to [target] and
  /// republishes the bundle.
  ///
  /// Mirrors what [XmppService.replenishPrekeys] does for the A track: each
  /// new inbound B-track session consumes one PQ one-time prekey, and once
  /// the pool drains every later handshake falls back to the signed PQ
  /// prekey, which weakens the forward secrecy of those sessions.
  ///
  /// Returns the number of keys added.
  ///
  /// When [republish] is false, only the local store is updated (caller will
  /// reconcile via [publish]). When true (default), a drained pool forces a
  /// B-track PEP write — still never touches classic OMEMO.
  Future<int> replenishPrekeys({int target = 5, bool republish = true}) async {
    final session = _session;
    if (session == null) return 0;

    var added = 0;
    final existing = session.device.pqOpks.keys.toSet();
    while (existing.length < target) {
      final id = _freshId(existing);
      existing.add(id);
      await session.device.generateSignedPqOpk(id);
      added++;
    }
    if (added == 0) return 0;

    await deviceStore.save(session.device);
    _log.info('replenished $added ML-KEM one-time prekey(s)');
    if (republish) {
      final minKem = target <= 1 ? target : target ~/ 2;
      await publish(force: true, minKemPreKeys: minKem < 1 ? 1 : minKem);
    }
    return added;
  }

  static int _freshId(Set<int> taken) {
    final rnd = Random.secure();
    var id = rnd.nextInt(0x7FFFFFFF);
    while (id == 0 || taken.contains(id)) {
      id = rnd.nextInt(0x7FFFFFFF);
    }
    return id;
  }

  /// Whether [peerJid] has at least one device that serves a PQ bundle.
  Future<bool> isPeerPqCapable(String peerJid) async {
    final bare = JID.fromString(peerJid).toBare();
    final devices = await tracks().loadPqDevices(bare);
    return devices.isNotEmpty;
  }

  Future<Omemo2Bundle> _toBundle(PqDevice device) async {
    await device.ensureStores();
    // Wire `<ik>` / `<spk>` are raw 32-byte keys (monocles getPublicKeyBytes);
    // signatures and the hybrid fingerprint use the 0x05-prefixed form.
    final ikSerialized = await device.identityPublicSerialized();
    final ikRaw = ikSerialized.sublist(1);
    final spkRaw = await device.spk.pk.getBytes();
    final prekeys = <int, String>{};
    for (final e in device.opks.entries) {
      prekeys[e.key] = base64Encode(await e.value.pk.getBytes());
    }

    final kemSpkTagged = serializeMlKem1024PublicKey(device.pqSpk);
    final kemSpkSig = device.pqSpkSignature;

    final kemPrekeys = <int, String>{};
    final kemSigs = <int, String>{};
    for (final e in device.pqOpks.entries) {
      final tagged = serializeMlKem1024PublicKey(e.value.publicRaw);
      kemPrekeys[e.key] = base64Encode(tagged);
      kemSigs[e.key] = base64Encode(e.value.signature);
    }

    final pqIk = await pqIdentity.publicKey();
    final transcript = await device.identityTranscript(pqIk);
    final pqSig = await pqIdentity.sign(transcript);
    // monocles: classical IK also signs the transcript (`<ik-sig>`). Without
    // this, peers refuse the bundle and never show our fingerprint.
    final ikSig = await device.sign(transcript);

    return Omemo2Bundle(
      deviceId: device.id,
      jid: device.jid,
      spk: base64Encode(spkRaw),
      spkId: device.spkId,
      spkSignature: base64Encode(device.spkSignature),
      ik: base64Encode(ikRaw),
      prekeys: prekeys,
      kemSpkId: device.pqSpkId,
      kemSpk: base64Encode(kemSpkTagged),
      kemSpkSignature: base64Encode(kemSpkSig),
      kemPrekeys: kemPrekeys,
      kemPrekeySignatures: kemSigs,
      pqIk: base64Encode(pqIk),
      pqSig: base64Encode(pqSig),
      ikSig: base64Encode(ikSig),
    );
  }

  /// Hybrid fingerprint for this account's OMEMO2 identity
  /// (monocles `getOwnHybridFingerprint`).
  Future<String?> hybridFingerprint() async {
    final device = _session?.device;
    if (device == null) return null;
    await device.ensureStores();
    final ik = await device.identityPublicSerialized();
    final pqIk = await pqIdentity.publicKey();
    return hybridOmemo2Fingerprint(ik, pqIk);
  }
}
