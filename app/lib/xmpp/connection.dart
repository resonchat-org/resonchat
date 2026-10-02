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
import '../omemo/protocol.dart';
import '../store/omemo_device_store.dart';
import 'b_track_manager.dart';
import 'capabilities.dart';
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
  }) async {
    await disconnect();
    _state = XmppConnectionState.connecting;

    _moxxOmemo = OmemoManager(
      // Lazy: an OMEMO event can arrive before the device is created.
      () => _omemoOrCreate(),
      (toJid, _) => _shouldEncrypt(toJid),
    );
    // Default to the capability-driven decision so encryption turns on by
    // itself once both sides support OMEMO.
    _shouldEncrypt = autoShouldEncrypt;
    final connection = XmppConnection(
      TestingReconnectionPolicy(),
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
    await connection.registerManagers([
      PresenceManager(),
      RosterManager(rosterState ?? TestingRosterStateManager(null, const [])),
      DiscoManager(const []),
      _pubsub!,
      MessageManager(),
      MessageDeliveryReceiptManager(),
      ChatStateManager(),
      MessageArchiveManagementManager(),
      _carbons!,
      _moxxOmemo!,
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
      ResourceBindingNegotiator(),
    ]);

    _eventsSub = connection.asBroadcastStream().listen(_onEvent);
    final result = await connection.connect(
      shouldReconnect: true,
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
      _moxxOmemo!.fetchDeviceList,
      _moxxOmemo!.fetchDeviceBundle,
      _moxxOmemo!.subscribeToDeviceListImpl,
      _moxxOmemo!.publishDeviceImpl,
    );
    _omemo = manager;
    return manager;
  }

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

  /// Fetches the roster and returns the entries (also cached by drift).
  Future<List<XmppRosterItem>> requestRoster() async {
    final rm = _connection?.getManagerById<RosterManager>(rosterManager);
    if (rm == null) return const [];
    final result = await rm.requestRoster();
    return result.isType<RosterRequestResult>()
        ? result.get<RosterRequestResult>().items
        : const [];
  }

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
        PqEncryptedData(encrypted),
      ]),
      type: 'chat',
    );
    return id;
  }

  /// Sends a chat message, requesting a delivery receipt (XEP-0184).
  /// Returns the stanza id used for the receipt, or null on failure.
  Future<String?> sendPlainText(
    JID to,
    String body, {
    bool requestReceipt = true,
    bool preferPq = true,
  }) async {
    // Try the B track first; it declines (returns null) unless every
    // recipient device is PQ-capable, so a standard peer still gets the
    // A track below.
    if (preferPq) {
      final pqId = await sendPqMessage(to, body, requestReceipt: requestReceipt);
      if (pqId != null) return pqId;
    }
    final mm = _connection?.getManagerById<MessageManager>(messageManager);
    if (mm == null) throw StateError('not connected');
    final id = _nextStanzaId();
    await mm.sendMessage(
      to,
      TypedMap<StanzaHandlerExtension>.fromList([
        MessageBodyData(body),
        MessageIdData(id),
        if (requestReceipt)
          const MessageDeliveryReceiptData(true),
      ]),
      type: 'chat',
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
      // A carbon is our own message from another resource: it must not be
      // stored as an inbound bubble (docs/03 §4).
      final isCarbon = event.get<CarbonsData>()?.isCarbon ?? false;
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
        ),
      );
    } else if (event is DeliveryReceiptReceivedEvent) {
      _deliveryReceipts.add(
        DeliveryReceipt(from: event.from, stanzaId: event.id),
      );
    } else if (event is PubSubNotificationEvent) {
      _onPepNotification(event);
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
