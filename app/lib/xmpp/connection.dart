// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// XMPP connection + baseline messaging (M1) with the A-track OMEMO
// manager attached (M2). All stanza crypto stays inside moxxmpp /
// omemo_dart; this class owns lifecycle and event fan-out.

import 'dart:async';

import 'package:logging/logging.dart';
import 'package:moxxmpp/moxxmpp.dart';
import 'package:moxxmpp_socket_tcp/moxxmpp_socket_tcp.dart';
import 'package:omemo_dart/omemo_dart.dart' as omemo_dart;

import '../omemo/defacto.dart';
import '../omemo/dual_track_manager.dart';
import '../omemo/track.dart';
import '../omemo/track_resolver.dart';
import '../omemo/protocol.dart';
import '../store/omemo_device_store.dart';
import 'b_track_manager.dart';
import 'eme.dart';
import 'capabilities.dart';
import 'pq_incoming.dart';
import 'pq_stanza.dart';

/// Decrypted inbound chat message, either track or plaintext.
class InboundMessage {
  InboundMessage({
    required this.from,
    required this.body,
    required this.stanzaId,
    this.encryptionError,
    this.isCarbonCopy = false,
    this.fromArchive = false,
    this.archiveTimestamp,
    this.track,
  });

  final JID from;
  final String body;

  /// The stanza id, needed to acknowledge delivery (XEP-0184).
  final String? stanzaId;

  /// Non-null when decryption failed; [body] is then empty and the UI
  /// must render an "unable to decrypt" placeholder (never drop it).
  final Object? encryptionError;

  /// True when this is our own message mirrored from another device
  /// (XEP-0280). Must not be shown as an inbound chat bubble.
  final bool isCarbonCopy;

  /// True when the message came from the MAM archive (XEP-0313) rather
  /// than live delivery.
  final bool fromArchive;

  /// Original send time for archived messages; live messages use now().
  final DateTime? archiveTimestamp;

  /// Which track the sender used, read from its EME declaration.
  ///
  /// Null when the sender declared an encryption scheme we do not
  /// implement, or none at all. It is deliberately independent of whether
  /// [body] decrypted: a message encrypted for someone else is still labelled
  /// with the track that was used, because that is the informative part.
  final Track? track;
}

/// The server rejected one of our outgoing messages.
class DeliveryFailure {
  const DeliveryFailure({
    required this.stanzaId,
    required this.from,
    required this.reason,
  });

  /// The id we sent with, so the stored row can be found.
  final String stanzaId;

  final JID from;

  /// Human-readable cause, e.g. `auth/forbidden: Access denied by service
  /// policy`.
  final String reason;

  @override
  String toString() => 'DeliveryFailure($stanzaId from $from: $reason)';
}

/// What arrived for one inbound message, before the UI sees it.
///
/// Diagnostic counterpart to [InboundMessage]: `encrypted` plus a null
/// `decryptionError` and an empty `body` is the signature of a message we
/// could not open, whereas no entry at all means the server never routed
/// it to us.
class MessageTrace {
  const MessageTrace({
    required this.from,
    required this.encrypted,
    required this.id,
    required this.type,
    required this.error,
    required this.decryptionError,
    required this.body,
  });

  final JID from;
  final bool encrypted;
  final String? id;
  final String? type;
  final String? error;
  final String? decryptionError;
  final String body;

  @override
  String toString() => 'MessageTrace(from=$from id=$id type=$type '
      'encrypted=$encrypted error=$error decryptionError=$decryptionError '
      'body=${body.isEmpty ? "<none>" : '"$body"'})';
}

/// The peer's typing state (XEP-0085).
enum TypingState { inactive, composing, paused }

/// Delivery status of an outgoing message (M1/M2).
enum DeliveryStatus { pending, delivered }

/// A delivery receipt for a message we sent (XEP-0184).
class DeliveryReceipt {
  const DeliveryReceipt({required this.from, required this.stanzaId});

  final JID from;

  /// The id of the message stanza that was delivered.
  final String stanzaId;
}

/// The peer's typing state within one chat (XEP-0085).
class TypingNotification {
  const TypingNotification({required this.from, required this.state});

  final JID from;
  final TypingState state;
}

/// Connection lifecycle state surfaced to the UI.
enum XmppConnectionState { disconnected, connecting, connected }

/// Whether an outgoing stanza should be OMEMO-encrypted. M1 default is
/// plaintext; the chat UI flips this per conversation (M2/M4).
typedef ShouldEncrypt = Future<bool> Function(JID to);

/// What a send on a chosen track actually did.
///
/// [track] is the track that went out, never the one that was asked for.
/// When [blocked] is set, nothing was sent and [stanzaId] is null.
class SendOutcome {
  const SendOutcome({
    required this.stanzaId,
    required this.track,
    this.blocked,
  });

  /// Null when nothing was sent.
  final String? stanzaId;

  /// The track asked for, and — when [stanzaId] is set — the one used.
  final Track track;

  /// Why the message could not be sent, if it could not.
  final TrackBlocked? blocked;

  /// True when a stanza went out.
  bool get sent => stanzaId != null;
}

class XmppService {
  XmppService({
    ShouldEncrypt? shouldEncrypt,
    this.deviceStore,
    this.bTrack,
  }) : _shouldEncrypt = shouldEncrypt ?? ((_) async => false);

  final Logger _log = Logger('XmppService');
  ShouldEncrypt _shouldEncrypt;

  /// Where our OMEMO device keys are persisted. When null the device is
  /// generated fresh each launch (development fallback only).
  final OmemoDeviceStore? deviceStore;

  /// B-track (PQ-OMEMO) support. Null disables the PQ track entirely and
  /// leaves the app on standard OMEMO.
  final BTrackManager? bTrack;

  /// A B-track message we could not open, reported instead of swallowed.
  Stream<PqDecryptFailure> get pqFailures => _pqFailures.stream;
  final _pqFailures = StreamController<PqDecryptFailure>.broadcast();

  XmppConnection? _connection;
  PubSubManager? _pubsub;
  omemo_dart.OmemoManager? _omemo;

  /// In-flight device initialisation, shared by racing callers.
  Future<omemo_dart.OmemoManager>? _omemoInit;
  OmemoManager? _moxxOmemo;
  CarbonsManager? _carbons;
  StreamSubscription<XmppEvent>? _eventsSub;
  final _inbound = StreamController<InboundMessage>.broadcast();
  final _deliveryReceipts = StreamController<DeliveryReceipt>.broadcast();
  final _typingStates = StreamController<TypingNotification>.broadcast();

  /// Fires when a PEP node we care about changes, so cached capabilities
  /// can be dropped instead of waiting out the TTL.
  final _capabilityChanges = StreamController<JID>.broadcast();
  Stream<JID> get capabilityChanges => _capabilityChanges.stream;

  XmppConnectionState _state = XmppConnectionState.disconnected;

  /// Overrides the automatic per-chat decision. Set by the settings UI.
  set shouldEncrypt(ShouldEncrypt fn) => _shouldEncrypt = fn;

  /// Consulted by [autoShouldEncrypt]; null means "derive from the
  /// capability service".
  ShouldEncrypt? _encryptOverride;

  set encryptOverride(ShouldEncrypt? fn) => _encryptOverride = fn;

  /// True when stanzas to [to] should be encrypted: either the user
  /// forced it, or the capability service says at least the standard
  /// track is safe for every recipient device.
  ///
  /// This is what moxxmpp's OmemoManager asks before wrapping a stanza,
  /// so a wrong `false` leaks plaintext while a wrong `true` produces
  /// unreadable ciphertext. We deliberately only return true when we are
  /// *sure* (docs/01 §7 invariant 1).
  Future<bool> autoShouldEncrypt(JID to) async {
    final override = _encryptOverride;
    if (override != null) return override(to);
    final caps = _capabilities == null
        ? null
        : await _capabilities!.forChat(to);
    if (caps == null || !caps.reliable) return false;
    return caps.mode != EncMode.none;
  }

  /// Capabilities for [to], or null when they could not be established.
  Future<ChatCapabilities?> capabilitiesFor(JID to) async {
    final caps = _capabilities;
    if (caps == null) return null;
    try {
      return await caps.forChat(to);
    } catch (e) {
      // A capability lookup that throws is indistinguishable, for our
      // purposes, from one that found nothing. Letting it escape would take
      // the send button down with it.
      _log.warning('capability lookup for $to failed: $e');
      return null;
    }
  }

  /// Sends [body] to [to] on exactly [track], or refuses.
  ///
  /// The single entry point for outbound chat messages. There is deliberately
  /// no variant that takes "any track that works": an argument like that is
  /// how a PQ message becomes plaintext without anybody deciding so.
  ///
  /// A blocked outcome means the message was not sent and the caller must
  /// ask the user. It does not retry on a different track.
  Future<SendOutcome> sendOnTrack(
    JID to,
    String body, {
    required Track track,
    bool requestReceipt = true,
  }) async {
    final caps = await capabilitiesFor(to);
    final resolution = resolveTrack(requested: track, capabilities: caps);
    if (!resolution.canSend) {
      _log.info(
        'refusing to send to $to on ${track.stored}: '
        '${resolution.blocked?.name}',
      );
      return SendOutcome(
        stanzaId: null,
        track: track,
        blocked: resolution.blocked,
      );
    }

    final String? stanzaId;
    switch (track) {
      case Track.pq:
        stanzaId = await sendPqMessage(to, body, requestReceipt: requestReceipt);
      case Track.standard:
        stanzaId = await sendOmemoMessage(to, body, requestReceipt: requestReceipt);
      case Track.none:
        stanzaId = await sendUnencryptedMessage(
          to,
          body,
          requestReceipt: requestReceipt,
        );
    }

    // A track that was judged sendable can still fail at the last moment —
    // a bundle goes stale between the check and the send. Returning the
    // requested track with a null stanza id says "nothing went out" without
    // pretending a different track was substituted.
    if (stanzaId == null) {
      return SendOutcome(
        stanzaId: null,
        track: track,
        blocked: switch (track) {
          Track.pq => TrackBlocked.pqUnavailable,
          Track.standard => TrackBlocked.standardUnavailable,
          Track.none => TrackBlocked.unreachableDevices,
        },
      );
    }
    return SendOutcome(stanzaId: stanzaId, track: track);
  }

  /// Attaches the capability resolver so [autoShouldEncrypt] works.
  void attachCapabilities(CapabilityService service) =>
      _capabilities = service;
  CapabilityService? _capabilities;

  XmppConnectionState get state => _state;
  Stream<InboundMessage> get inbound => _inbound.stream;

  /// Receipts for messages we sent (XEP-0184).
  Stream<DeliveryReceipt> get deliveryReceipts => _deliveryReceipts.stream;

  /// Peer typing/composing notifications (XEP-0085).
  Stream<TypingNotification> get typingStates => _typingStates.stream;

  /// Every inbound message stanza as it came off the wire, before any
  /// decryption. Diagnostic counterpart to [inbound].
  Stream<MessageTrace> get rawMessages => _rawMessages.stream;
  final _rawMessages = StreamController<MessageTrace>.broadcast();

  /// Messages the server refused, keyed by the stanza id we sent them with.
  ///
  /// A `<message type='error'/>` carrying our own id means the stanza never
  /// left the server. The most common cause in practice is a service policy
  /// that refuses anything outside mutual subscriptions, which is worth
  /// telling the user about rather than showing a bubble that looks sent.
  Stream<DeliveryFailure> get deliveryFailures => _deliveryFailures.stream;
  final _deliveryFailures = StreamController<DeliveryFailure>.broadcast();

  OmemoManager? get moxxOmemo => _moxxOmemo;
  omemo_dart.OmemoManager? get omemo => _omemo;

  /// PubSub/PEP manager; null until connected. The B track publishes and
  /// fetches its device list and bundles through it.
  PubSubManager? get pubsub => _pubsub;

  /// The underlying connection, for callers that need a manager this class
  /// does not wrap (roster edits, presence, diagnostics).
  XmppConnection? get connection => _connection;

  /// Sends an "available" presence, announcing this resource to contacts.
  Future<void> sendAvailablePresence() async {
    await _connection?.getManagerById<PresenceManager>(presenceManager)
        ?.sendInitialPresence();
  }

  PresenceManager? _presenceManager() =>
      _connection?.getManagerById<PresenceManager>(presenceManager);

  /// Asks [peer] for a presence subscription.
  Future<void> requestSubscription(JID peer) async {
    await _presenceManager()?.requestSubscription(peer.toBare());
  }

  /// Grants a subscription [peer] asked for.
  ///
  /// Without this the relationship stays one-sided and most servers refuse
  /// to route messages between non-contacts, which looks exactly like a
  /// delivery bug.
  Future<void> acceptSubscription(JID peer) async {
    await _presenceManager()?.acceptSubscriptionRequest(peer.toBare());
  }

  /// Approves every subscription request that arrives, so a peer can add us
  /// without anyone touching the UI. Returns the peers approved.
  Stream<JID> get subscriptionRequests => _subscriptionRequests.stream;
  final _subscriptionRequests = StreamController<JID>.broadcast();

  /// True once the server accepted our Carbons enable request.
  bool get carbonsEnabled => _carbonsEnabled;
  bool _carbonsEnabled = false;

  /// Reason the last [connect] failed, for display in the UI.
  String? lastError;

  /// Whether the server advertises the MAM archive (XEP-0313). Queried
  /// lazily; cached per connection.
  bool get mamAvailable => _mamAvailable;
  bool _mamAvailable = false;

  /// Connects, logs in, and attaches roster/MAM-bootstrap managers.
  /// Returns true on successful SASL + resource binding.
  Future<bool> connect({
    required String jid,
    required String password,
    String? host,
    int? port,
    BaseRosterStateManager? rosterState,
    bool reconnect = true,
  }) async {
    await disconnect();
    _state = XmppConnectionState.connecting;
    _rosterState = rosterState;

    _moxxOmemo = OmemoManager(
      // Lazy: an OMEMO event can arrive before the device is created.
      () => _omemoOrCreate(),
      // Only chat messages are ever candidates for encryption. Letting the
      // hook run for every outgoing stanza made capability resolution fire
      // for each PubSub IQ, and each of those queries is itself a stanza
      // that goes through this hook — an unbounded IQ cascade that starved
      // the login sequence until the UI hung on "Connecting…".
      (toJid, stanza) async =>
          stanza.tag == 'message' && await _shouldEncrypt(toJid),
    );
    // Default to the capability-driven decision so encryption turns on by
    // itself once both sides support OMEMO.
    _shouldEncrypt = autoShouldEncrypt;
    final connection = XmppConnection(
      reconnect ? TestingReconnectionPolicy() : NeverReconnectPolicy(),
      // TODO(M7): replace with a connectivity_plus-backed manager plus
      // XEP-0357 push so Doze-mode delivery works without a permanent
      // radio lock (Briar's always-on lesson, docs/09).
      AlwaysConnectedConnectivityManager(),
      ClientToServerNegotiator(),
      TCPSocketWrapper(false),
    )..connectionSettings = ConnectionSettings(
        jid: JID.fromString(jid),
        password: password,
        host: host,
        port: port,
      );

    _carbons = CarbonsManager();
    _pubsub = PubSubManager();
    final messageManager = MessageManager();
    // The B track rides along as a stanza extension, and moxxmpp only knows
    // how to serialise the ones it ships with. Without this callback the PQ
    // ciphertext is silently dropped and the stanza leaves in plaintext with
    // the "encrypted, use another client" body - the worst possible outcome:
    // it looks like it worked.
    messageManager.registerMessageSendingCallback(pqSendingCallback);
    await connection.registerManagers([
      PresenceManager(),
      RosterManager(
        rosterState ?? (_rosterState = TestingRosterStateManager(null, const [])),
      ),
      DiscoManager(const []),
      _pubsub!,
      messageManager,
      MessageDeliveryReceiptManager(),
      ChatStateManager(),
      MessageArchiveManagementManager(),
      _carbons!,
      _moxxOmemo!,
      // XEP-0380. Without it the received message carries no record of which
      // track the sender used, so every encrypted message from another client
      // would be labelled as unencrypted.
      EmeManager(),
      // B-track inbound. moxxmpp has no handler for the PQ namespace, so
      // without this an incoming PQ message arrives as the literal fallback
      // body with no error: a silent, perfectly plausible-looking delivery.
      PqIncomingManager(_decryptIncomingPq, (failure) {
        _log.warning('inbound PQ message not opened: ${failure.reason}');
        if (!_pqFailures.isClosed) _pqFailures.add(failure);
      }),
    ]);
    await connection.registerFeatureNegotiators([
      StartTlsNegotiator(),
      // Preferred order: strongest first. moxxmpp picks the first
      // negotiator whose mechanism the server advertises, so servers
      // without SCRAM-SHA-256 (e.g. conversations.im offers PLAIN and
      // SCRAM-SHA-1 only) still authenticate.
      SaslScramNegotiator(30, '', '', ScramHashType.sha256),
      SaslScramNegotiator(20, '', '', ScramHashType.sha512),
      SaslScramNegotiator(10, '', '', ScramHashType.sha1),
      SaslPlainNegotiator(),
      // Roster versioning (RFC 6121). Without this negotiator registered,
      // RosterManager.requestRoster() dereferences a null negotiator and
      // the whole roster fetch dies - which is the first thing the login
      // flow does.
      RosterFeatureNegotiator(),
      ResourceBindingNegotiator(),
    ]);

    _eventsSub = connection.asBroadcastStream().listen(_onEvent);
    final result = await connection.connect(
      shouldReconnect: reconnect,
      waitUntilLogin: true,
    );
    final ok = result.isType<bool>() && result.get<bool>();
    if (!ok) {
      // Surface the actual reason: "authentication failed" is useless
      // when the real cause is a TLS or SRV problem.
      lastError = result.isType<XmppError>()
          ? '${result.get<XmppError>()}'
          : 'connection failed (${result.dataRuntimeType})';
      _log.severe('connect failed: $lastError');
    }
    _connection = ok ? connection : null;
    _state =
        ok ? XmppConnectionState.connected : XmppConnectionState.disconnected;
    if (ok) {
      _carbonsEnabled = await _carbons!.enableCarbons();
      _mamAvailable = await _isMamAvailable();
      _log.info('carbons: $_carbonsEnabled, mam: $_mamAvailable');
      await _subscribeOwnPep();
    }
    _log.info('connect($jid): $ok');
    return ok;
  }

  /// PEP nodes worth a subscription: both OMEMO dialects plus the PQ track.
  ///
  /// The de-facto node is what real clients announce on, so subscribing
  /// only to the XEP-0384 spec node means we would never see a peer add a
  /// device.
  static const List<String> _subscribedPepNodes = <String>[
    omemoDefactoDevicesNode,
    ...omemoSpecDevicesNodes,
    pomemoDevicesXmlns,
    pomemoBundlesXmlns,
  ];

  /// Subscribes to our own OMEMO device list so the server pushes device
  /// changes to us (which also keeps our peers' lists fresh when they
  /// republish). Peer nodes are subscribed lazily on first use.
  Future<void> _subscribeOwnPep() async {
    final pm = _pubsub;
    if (pm == null) return;
    final bare = _connection!.connectionSettings.jid.toBare();
    for (final node in _subscribedPepNodes) {
      final result = await pm.subscribe(bare, node);
      if (!result.isType<bool>() || !result.get<bool>()) {
        _log.fine('could not subscribe to $node: $result');
      }
    }
  }

  /// Subscribes to a peer's OMEMO device list so we learn about new devices
  /// immediately instead of waiting out the capability TTL.
  Future<void> subscribePeerPep(JID peer) async {
    final pm = _pubsub;
    if (pm == null) return;
    final bare = peer.toBare();
    for (final node in _subscribedPepNodes) {
      await pm.subscribe(bare, node);
    }
  }

  /// Asks the server whether it keeps a message archive.
  Future<bool> _isMamAvailable() async {
    final dm = _connection?.getManagerById<DiscoManager>(discoManager);
    if (dm == null) return false;
    try {
      return await dm.supportsFeature(
        _connection!.connectionSettings.serverJid,
        mamXmlns,
      );
    } catch (_) {
      return false;
    }
  }

  /// Pulls archived messages for one chat (XEP-0313).
  ///
  /// Returned messages are replayed through the normal inbound pipeline
  /// (with `fromArchive` set), so they are decrypted and stored exactly
  /// like live traffic. [beforeId] pages backwards through history;
  /// returns the number of messages the server sent, or null on error.
  Future<int?> fetchHistory(
    JID chatJid, {
    String? beforeId,
    int? pageSize = 50,
  }) async {
    final mm =
        _connection?.getManagerById<MessageArchiveManagementManager>(
              mamManager,
            );
    if (mm == null) return null;
    final result = await mm.requestMessages(
      chatJid,
      beforeId: beforeId,
      pageSize: pageSize,
    );
    return result.isType<int>() ? result.get<int>() : null;
  }

  /// Returns our omemo_dart manager, creating and restoring the device on
  /// first use.
  ///
  /// This is called from moxxmpp's own event handler, so it *will* run
  /// before the app has finished starting: an OMEMO device-list push or a
  /// bundle fetch can arrive during [connect], long before anything has
  /// called [ensureOmemoDevice]. Dereferencing a not-yet-created manager
  /// there crashed the connection outright, so the device is built lazily
  /// here instead.
  ///
  /// Restoring matters: a fresh device id on every start would keep
  /// appending to our own PEP device list and make peers encrypt to
  /// devices we no longer hold keys for.
  Future<omemo_dart.OmemoManager> _omemoOrCreate({int opkAmount = 20}) async {
    final existing = _omemo;
    if (existing != null) return existing;
    // Several events can race here; building twice would orphan the first
    // device's keys, so the in-flight initialisation is shared.
    return _omemoInit ??= _buildOmemo(opkAmount: opkAmount).whenComplete(() {
      _omemoInit = null;
    });
  }

  Future<omemo_dart.OmemoManager> _buildOmemo({required int opkAmount}) async {
    final bareJid =
        _connection!.connectionSettings.jid.toBare().toString();

    omemo_dart.OmemoDevice device;
    final restored = await deviceStore?.load();
    if (restored != null && restored.jid == bareJid) {
      device = restored;
      _log.info('restored OMEMO device ${device.id}');
    } else {
      device = await omemo_dart.OmemoDevice.generateNewDevice(
        bareJid,
        opkAmount: opkAmount,
      );
      _log.info('generated new OMEMO device ${device.id}');
    }

    final manager = omemo_dart.OmemoManager(
      device,
      omemo_dart.BlindTrustBeforeVerificationTrustManager(),
      _moxxOmemo!.sendEmptyMessageImpl,
      // The inbound path must use the same dual-dialect readers as the
      // outbound one. moxxmpp's fetchDeviceList only knows the XEP-0384 spec
      // node, so it reported an empty list for every real peer and
      // decryption aborted with "not tracked in device list".
      _fetchDeviceListDialectAware,
      _fetchDeviceBundleDialectAware,
      _subscribeToDeviceListDialectAware,
      _publishDeviceDialectAware,
    );
    _omemo = manager;
    return manager;
  }

  /// Device list for [jid] across both OMEMO wire dialects.
  Future<List<int>?> _fetchDeviceListDialectAware(String jid) async {
    final resolved =
        await tracks?.resolveOmemoDevices(JID.fromString(jid)) ??
            (devices: const <int>{}, listReadable: false);
    if (!resolved.listReadable) return null;
    return resolved.devices.toList();
  }

  /// Bundle for one device across both OMEMO wire dialects.
  Future<omemo_dart.OmemoBundle?> _fetchDeviceBundleDialectAware(
    String jid,
    int deviceId,
  ) async {
    return tracks?.getOmemoBundle(JID.fromString(jid), deviceId);
  }

  Future<void> _subscribeToDeviceListDialectAware(String jid) =>
      _moxxOmemo!.subscribeToDeviceListImpl(jid);

  Future<void> _publishDeviceDialectAware(
    omemo_dart.OmemoDevice device,
  ) =>
      _moxxOmemo!.publishDeviceImpl(device);

  /// Creates (or restores) our OMEMO device and publishes its bundle.
  ///
  /// Safe to call before the device exists — see [_omemoOrCreate] for why
  /// the creation cannot assume it is the first caller.
  Future<int> ensureOmemoDevice({int opkAmount = 20}) async {
    final manager = await _omemoOrCreate(opkAmount: opkAmount);
    final id = await manager.getDeviceId();
    final device = await manager.getDevice();
    final bundle = await device.toBundle();
    final bare = JID.fromString(_connection!.connectionSettings.jid.toBare().toString());

    // Publish through the dual-track manager so the bundle lands in both
    // the de-facto and the XEP-0384 dialects. Publishing only the spec form
    // makes us invisible to every client that actually exists.
    final published = tracks == null
        ? await _moxxOmemo!.publishBundle(bundle).then(
              // moxxmpp's payload bool is
              // `deviceBundlePublish.isType<PubSubError>()` — true means
              // failure.
              (r) => r.isType<bool>() && !r.get<bool>(),
              onError: (_) => false,
            )
        : await tracks!.publishOmemoBundle(bare, bundle);
    if (!published) {
      _log.warning('OMEMO bundle publish reported failure');
    }

    // Persist only after a confirmed publish so we never store keys the
    // server does not know about.
    if (published) {
      await deviceStore?.save(device);
    }
    return id;
  }

  /// Publishes our standard-OMEMO bundle in both wire dialects.
  ///
  /// The app sets this so [ensureOmemoDevice] does not have to reach back
  /// into the provider graph.
  DualTrackManager? tracks;

  /// Tops the one-time-prekey pool back up to [target] and republishes the
  /// bundle. omemo_dart burns one OPK per new inbound session, so without
  /// this the pool drains and later sessions lose forward secrecy by
  /// falling back to the signed prekey.
  ///
  /// Call after [ensureOmemoDevice]; safe to call repeatedly.
  Future<int> replenishPrekeys({int target = 20}) async {
    final om = _omemo;
    if (om == null) return 0;
    final added = await om.replenishOnetimePrekeys(target);
    if (added > 0) {
      // Keep the local copy in sync with what peers can now fetch.
      await deviceStore?.save(await om.getDevice());
    }
    return added;
  }

  /// Number of one-time prekeys still available locally.
  Future<int> availablePrekeyCount() async {
    final om = _omemo;
    if (om == null) return 0;
    return (await om.getDevice()).opks.length;
  }

  /// Creates and publishes our B-track (PQ) device.
  ///
  /// Safe to call when the B track is unavailable; returns false then.
  Future<bool> initialiseBTrack() async {
    final track = bTrack;
    if (track == null) return false;
    final bare = _connection?.connectionSettings.jid.toBare().toString();
    if (bare == null) return false;
    return track.initialise(bare);
  }

  /// Whether our PQ bundle is published and ready to use.
  bool get bTrackReady => bTrack?.ready ?? false;

  /// Fetches the roster and returns **every** entry.
  ///
  /// The returned list must come from the local cache, not from the IQ.
  /// With RFC 6121 versioning a server that has nothing to report answers
  /// with an empty `<iq/>`, and moxxmpp faithfully turns that into an empty
  /// item list — so returning it would empty the contact list on every start
  /// after the first. The cache already holds the delta applied, so it is
  /// the authoritative full roster.
  Future<List<XmppRosterItem>> requestRoster() async {
    final rm = _connection?.getManagerById<RosterManager>(rosterManager);
    if (rm == null) return const [];
    await rm.requestRoster();
    final cached = await _rosterState?.loadRosterCache();
    return cached?.roster ?? const [];
  }

  /// The roster store in use, so [requestRoster] can read the full list.
  BaseRosterStateManager? _rosterState;

  /// Opens an inbound B-track message, if this device is a recipient.
  Future<String?> _decryptIncomingPq(Stanza stanza) async {
    final payload = extractPqPayload(stanza);
    if (payload == null) return null;
    final track = bTrack;
    if (track == null || !track.ready) return null;
    final plaintext = await track.decryptIfPossible(payload);
    if (plaintext == null) return null;
    // Each new inbound PQ session burns one one-time prekey; refilling keeps
    // forward secrecy from quietly degrading to the signed prekey for the
    // rest of this device's life.
    unawaited(track.replenishPrekeys());
    return plaintext;
  }

  /// Serialises the B track's ciphertext

  /// Encrypts and sends [body] on the PQ track when [to] is fully PQ-capable,
  /// otherwise returns null so the caller can fall back to the A track.
  ///
  /// Never sends an encrypted message that a recipient cannot open: if the
  /// peer has no PQ devices, or encryption fails for every device, we
  /// return null instead of emitting unreadable ciphertext (invariant 1).
  Future<String?> sendPqMessage(
    JID to,
    String body, {
    bool requestReceipt = true,
  }) async {
    final track = bTrack;
    if (track == null || !track.ready) return null;

    final encrypted = await track.encryptIfPossible(
      peerJid: to.toBare().toString(),
      plaintext: body,
    );
    if (encrypted == null) return null;

    final mm = _connection?.getManagerById<MessageManager>(messageManager);
    if (mm == null) throw StateError('not connected');
    final id = _nextStanzaId();

    await mm.sendMessage(
      to,
      TypedMap<StanzaHandlerExtension>.fromList([
        MessageBodyData(encryptedBodyFallback),
        MessageIdData(id),
        if (requestReceipt) const MessageDeliveryReceiptData(true),
        // XEP-0380: declare the track so the receiver can label the message
        // without decrypting it, and so a client that does not know this
        // namespace shows our name rather than guessing.
        const EmeData(Track.pq, name: 'OMEMO-PQ'),
        PqEncryptedData(encrypted),
      ]),
      type: 'chat',
    );
    return id;
  }

  /// Sends on the standard OMEMO track.
  ///
  /// No EME element here on purpose: moxxmpp's OmemoManager adds the
  /// declaration itself, and only once it has actually encrypted the stanza.
  /// Adding a second one from this side would either duplicate the element
  /// or, worse, claim encryption on a message that went out in plaintext.
  ///
  /// The caller has already established that the standard track is reachable
  /// for every recipient device, which is also what tells moxxmpp's
  /// `shouldEncrypt` hook to wrap this stanza.
  Future<String?> sendOmemoMessage(
    JID to,
    String body, {
    bool requestReceipt = true,
  }) async {
    final mm = _connection?.getManagerById<MessageManager>(messageManager);
    if (mm == null) throw StateError('not connected');
    final id = _nextStanzaId();
    await mm.sendMessage(
      to,
      TypedMap<StanzaHandlerExtension>.fromList([
        MessageBodyData(body),
        MessageIdData(id),
        if (requestReceipt) const MessageDeliveryReceiptData(true),
      ]),
      type: 'chat',
    );
    return id;
  }

  /// Sends a chat message in the clear, requesting a delivery receipt
  /// (XEP-0184).
  ///
  /// Only reachable once the user has chosen [Track.none] and been told what
  /// it means. There is no capability check here and deliberately no
  /// encryption attempt: this method does exactly one thing, so there is no
  /// path where calling it "for safety" quietly encrypts, and none where
  /// failing to encrypt produces something that looks protected.
  Future<String?> sendUnencryptedMessage(
    JID to,
    String body, {
    bool requestReceipt = true,
  }) async {
    final connection = _connection;
    if (connection == null) throw StateError('not connected');
    final id = _nextStanzaId();

    // Built here rather than through MessageManager so `shouldEncrypt: false`
    // is stated on the stanza itself.
    //
    // The alternative — flipping a shared flag that the `shouldEncrypt` hook
    // reads — makes the decision depend on which send happens to be in flight
    // at the moment the hook runs. A plaintext send racing an encrypted one to
    // the same contact would then take the wrong one with it. Per-stanza is
    // the only place this can be decided without a race.
    final children = <XMLNode>[
      MessageBodyData(body).toXML(),
      if (requestReceipt) MessageDeliveryReceiptData(true).toXML(),
    ];
    await connection.sendStanza(
      StanzaDetails(
        Stanza.message(
          to: to.toString(),
          id: id,
          type: 'chat',
          children: children,
        ),
        awaitable: false,
        shouldEncrypt: false,
      ),
    );
    return id;
  }

  /// Publishes our typing state to [to] (XEP-0085).
  Future<void> sendChatState(JID to, TypingState state) async {
    final mm = _connection?.getManagerById<MessageManager>(messageManager);
    if (mm == null) throw StateError('not connected');
    final xmppState = switch (state) {
      TypingState.composing => ChatState.composing,
      TypingState.paused => ChatState.paused,
      TypingState.inactive => ChatState.active,
    };
    await mm.sendMessage(
      to,
      TypedMap<StanzaHandlerExtension>.fromList([xmppState]),
      type: 'chat',
    );
  }

  var _stanzaCounter = 0;

  /// Locally-unique stanza id. XEP-0184 receipts reference this value.
  String _nextStanzaId() {
    _stanzaCounter++;
    return 'resonchat-${DateTime.now().microsecondsSinceEpoch}-$_stanzaCounter';
  }

  Future<void> disconnect() async {
    await _eventsSub?.cancel();
    _eventsSub = null;
    await _connection?.disconnect();
    _connection = null;
    _state = XmppConnectionState.disconnected;
  }

  void _onEvent(XmppEvent event) {
    if (event is MessageEvent) {
      final error = event.encryptionError;
      // Our own message coming back as an error: it was refused, not
      // delivered. Report it before anything else so the UI can correct the
      // stored row instead of leaving a bubble that looks sent.
      final stanzaError = event.error;
      if (stanzaError != null && event.id != null && !event.encrypted) {
        if (!_deliveryFailures.isClosed) {
          _deliveryFailures.add(
            DeliveryFailure(
              stanzaId: event.id!,
              from: event.from,
              reason: describeStanzaError(stanzaError),
            ),
          );
        }
        return;
      }
      // A carbon is our own message from another resource: it must not be
      // stored as an inbound bubble (docs/03 §4).
      final isCarbon = event.get<CarbonsData>()?.isCarbon ?? false;
      // An undecryptable carbon is not a lost message. It is one of our own
      // outgoing messages mirrored to this resource, encrypted for the
      // *peer's* devices — we were never a recipient, so nobody lost
      // anything. Showing "Unable to decrypt" for it invents a problem.
      if (isCarbon && error != null) {
        _log.fine(
          'dropping undecryptable carbon from ${event.from}: '
          'we were not a recipient of our own message',
        );
        return;
      }
      final mam = event.get<MAMData>();
      final state = event.get<ChatState>();
      if (state != null) {
        _typingStates.add(
          TypingNotification(
            from: event.from,
            state: switch (state) {
              ChatState.composing => TypingState.composing,
              ChatState.paused => TypingState.paused,
              _ => TypingState.inactive,
            },
          ),
        );
        // A chat-state-only message carries no body; nothing to store.
        return;
      }
      // XEP-0380: the sender's declaration of what it used. Absent means
      // plaintext, which is the only honest reading.
      final eme = event.get<ExplicitEncryptionType>();
      final foreign = Track.isForeignEncryption(eme);
      _inbound.add(
        InboundMessage(
          from: event.from,
          body:
              error != null ? '' : (event.get<MessageBodyData>()?.body ?? ''),
          stanzaId: event.id,
          encryptionError: error,
          isCarbonCopy: isCarbon,
          fromArchive: mam != null,
          archiveTimestamp: mam?.delay.timestamp,
          track: foreign ? null : Track.fromEme(eme),
        ),
      );
    } else if (event is DeliveryReceiptReceivedEvent) {
      _deliveryReceipts.add(
        DeliveryReceipt(from: event.from, stanzaId: event.id),
      );
    } else if (event is PubSubNotificationEvent) {
      _onPepNotification(event);
    } else if (event is MessageEvent) {
      // Raw view of every message stanza, before decryption is attempted.
      // A caller diagnosing "nothing arrived" needs to tell routing apart
      // from decryption, and only the raw form can do that.
      _rawMessages.add(
        MessageTrace(
          from: event.from,
          id: event.id,
          type: event.type,
          encrypted: event.encrypted,
          error: event.error?.toString(),
          decryptionError: event.encryptionError?.toString(),
          body: event.get<MessageBodyData>()?.body ?? '',
        ),
      );
    } else if (event is SubscriptionRequestReceivedEvent) {
      // Approve automatically: a contact adding us must not require a tap.
      final from = JID.fromString('${event.from}');
      unawaited(acceptSubscription(from).then(
        (_) {
          if (!_subscriptionRequests.isClosed) {
            _subscriptionRequests.add(from.toBare());
          }
        },
      ));
      _log.info('approved presence subscription from ${event.from}');
    }
  }

  /// A peer added or removed a device, or republished a bundle. Their PQ
  /// capability may have flipped, so the cached answer must go.
  void _onPepNotification(PubSubNotificationEvent event) {
    final node = event.item.node;
    if (!_subscribedPepNodes.contains(node)) {
      return;
    }
    final owner = JID.fromString(event.from).toBare();
    _log.info('PEP change on $node by $owner; dropping cached capabilities');
    _capabilities?.invalidate(owner);
    if (!_capabilityChanges.isClosed) _capabilityChanges.add(owner);
  }
}

/// Reconnection policy that never reconnects.
///
/// Used by probes and headless tools: an automatic reconnect turns a dropped
/// stream into an unhandled socket error inside the caller's zone, which
/// buries whatever the caller was actually measuring. Reconnecting is the
/// app's job and is done deliberately, with backoff.
class NeverReconnectPolicy extends ReconnectionPolicy {
  @override
  Future<void> onSuccess() async {}

  @override
  Future<void> onFailure() async {}
}

/// Renders a stanza error as something worth showing a user.
///
/// The server's own wording is kept verbatim: "Access denied by service
/// policy" and "service-unavailable" call for completely different
/// responses, and paraphrasing them into one generic string would hide that.
String describeStanzaError(StanzaError error) {
  if (error is GenericStanzaError) {
    final text = error.text.isEmpty ? '' : ': ${error.text}';
    return '${error.type}/${error.condition}$text';
  }
  return error.toString();
}
