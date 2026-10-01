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

import '../store/omemo_device_store.dart';

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
  }) : _shouldEncrypt = shouldEncrypt ?? ((_) async => false);

  final Logger _log = Logger('XmppService');
  ShouldEncrypt _shouldEncrypt;

  /// Where our OMEMO device keys are persisted. When null the device is
  /// generated fresh each launch (development fallback only).
  final OmemoDeviceStore? deviceStore;

  XmppConnection? _connection;
  omemo_dart.OmemoManager? _omemo;
  OmemoManager? _moxxOmemo;
  CarbonsManager? _carbons;
  StreamSubscription<XmppEvent>? _eventsSub;
  final _inbound = StreamController<InboundMessage>.broadcast();
  final _deliveryReceipts = StreamController<DeliveryReceipt>.broadcast();
  final _typingStates = StreamController<TypingNotification>.broadcast();
  XmppConnectionState _state = XmppConnectionState.disconnected;

  set shouldEncrypt(ShouldEncrypt fn) => _shouldEncrypt = fn;

  XmppConnectionState get state => _state;
  Stream<InboundMessage> get inbound => _inbound.stream;

  /// Receipts for messages we sent (XEP-0184).
  Stream<DeliveryReceipt> get deliveryReceipts => _deliveryReceipts.stream;

  /// Peer typing/composing notifications (XEP-0085).
  Stream<TypingNotification> get typingStates => _typingStates.stream;

  OmemoManager? get moxxOmemo => _moxxOmemo;
  omemo_dart.OmemoManager? get omemo => _omemo;

  /// True once the server accepted our Carbons enable request.
  bool get carbonsEnabled => _carbonsEnabled;
  bool _carbonsEnabled = false;

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
      () async => _omemo!,
      (toJid, _) => _shouldEncrypt(toJid),
    );
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
    await connection.registerManagers([
      PresenceManager(),
      RosterManager(rosterState ?? TestingRosterStateManager(null, const [])),
      DiscoManager(const []),
      PubSubManager(),
      MessageManager(),
      MessageDeliveryReceiptManager(),
      ChatStateManager(),
      MessageArchiveManagementManager(),
      _carbons!,
      _moxxOmemo!,
    ]);
    await connection.registerFeatureNegotiators([
      StartTlsNegotiator(),
      SaslScramNegotiator(10, '', '', ScramHashType.sha256),
      ResourceBindingNegotiator(),
    ]);

    _eventsSub = connection.asBroadcastStream().listen(_onEvent);
    final result = await connection.connect(
      shouldReconnect: true,
      waitUntilLogin: true,
    );
    final ok = result.isType<bool>() && result.get<bool>();
    _connection = ok ? connection : null;
    _state =
        ok ? XmppConnectionState.connected : XmppConnectionState.disconnected;
    if (ok) {
      _carbonsEnabled = await _carbons!.enableCarbons();
      _mamAvailable = await _isMamAvailable();
      _log.info('carbons: $_carbonsEnabled, mam: $_mamAvailable');
    }
    _log.info('connect($jid): $ok');
    return ok;
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

  /// Creates (or restores) our OMEMO device. Call after [connect].
  ///
  /// Restoring matters: a fresh device id on every start would keep
  /// appending to our own PEP device list and make peers encrypt to
  /// devices we no longer hold keys for.
  Future<int> ensureOmemoDevice({int opkAmount = 20}) async {
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

    _omemo = omemo_dart.OmemoManager(
      device,
      omemo_dart.BlindTrustBeforeVerificationTrustManager(),
      _moxxOmemo!.sendEmptyMessageImpl,
      _moxxOmemo!.fetchDeviceList,
      _moxxOmemo!.fetchDeviceBundle,
      _moxxOmemo!.subscribeToDeviceListImpl,
      _moxxOmemo!.publishDeviceImpl,
    );
    final id = await _omemo!.getDeviceId();
    final bundle = await (await _omemo!.getDevice()).toBundle();
    final published = await _moxxOmemo!.publishBundle(bundle);
    if (!published.isType<bool>() || !published.get<bool>()) {
      _log.warning('OMEMO bundle publish reported failure');
    }

    // Persist after a successful publish so we never store keys the
    // server does not know about.
    if (published.isType<bool>() && published.get<bool>()) {
      await deviceStore?.save(device);
    }
    return id;
  }

  /// Fetches the roster and returns the entries (also cached by drift).
  Future<List<XmppRosterItem>> requestRoster() async {
    final rm = _connection?.getManagerById<RosterManager>(rosterManager);
    if (rm == null) return const [];
    final result = await rm.requestRoster();
    return result.isType<RosterRequestResult>()
        ? result.get<RosterRequestResult>().items
        : const [];
  }

  /// Sends a chat message, requesting a delivery receipt (XEP-0184).
  /// Returns the stanza id used for the receipt, or null on failure.
  Future<String?> sendPlainText(
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
    }
  }
}
