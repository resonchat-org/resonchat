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

/// Decrypted inbound chat message, either track or plaintext.
class InboundMessage {
  InboundMessage({
    required this.from,
    required this.body,
    this.encryptionError,
  });

  final JID from;
  final String body;

  /// Non-null when decryption failed; [body] is then empty and the UI
  /// must render an "unable to decrypt" placeholder (never drop it).
  final Object? encryptionError;
}

/// Connection lifecycle state surfaced to the UI.
enum XmppConnectionState { disconnected, connecting, connected }

/// Whether an outgoing stanza should be OMEMO-encrypted. M1 default is
/// plaintext; the chat UI flips this per conversation (M2/M4).
typedef ShouldEncrypt = Future<bool> Function(JID to);

class XmppService {
  XmppService({ShouldEncrypt? shouldEncrypt})
      : _shouldEncrypt = shouldEncrypt ?? ((_) async => false);

  final Logger _log = Logger('XmppService');
  ShouldEncrypt _shouldEncrypt;

  XmppConnection? _connection;
  omemo_dart.OmemoManager? _omemo;
  OmemoManager? _moxxOmemo;
  StreamSubscription<XmppEvent>? _eventsSub;
  final _inbound = StreamController<InboundMessage>.broadcast();
  XmppConnectionState _state = XmppConnectionState.disconnected;

  set shouldEncrypt(ShouldEncrypt fn) => _shouldEncrypt = fn;

  XmppConnectionState get state => _state;
  Stream<InboundMessage> get inbound => _inbound.stream;
  OmemoManager? get moxxOmemo => _moxxOmemo;
  omemo_dart.OmemoManager? get omemo => _omemo;

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

    await connection.registerManagers([
      PresenceManager(),
      RosterManager(rosterState ?? TestingRosterStateManager(null, const [])),
      DiscoManager(const []),
      PubSubManager(),
      MessageManager(),
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
    _log.info('connect($jid): $ok');
    return ok;
  }

  /// Creates (or restores) our OMEMO device. Call after [connect].
  Future<int> ensureOmemoDevice({int opkAmount = 20}) async {
    // TODO(M5): persist the device in SQLCipher + Keystore instead of
    // generating fresh each install; publish rotation on prekey low-water.
    final device = await omemo_dart.OmemoDevice.generateNewDevice(
      _connection!.connectionSettings.jid.toBare().toString(),
      opkAmount: opkAmount,
    );
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

  Future<void> sendPlainText(JID to, String body) async {
    final mm =
        _connection?.getManagerById<MessageManager>(messageManager);
    if (mm == null) throw StateError('not connected');
    await mm.sendMessage(
      to,
      TypedMap<StanzaHandlerExtension>.fromList([MessageBodyData(body)]),
      type: 'chat',
    );
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
      _inbound.add(
        InboundMessage(
          from: event.from,
          body: error != null
              ? ''
              : (event.get<MessageBodyData>()?.body ?? ''),
          encryptionError: error,
        ),
      );
    }
  }
}
