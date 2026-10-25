// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Conversations-style multi-account hub: one [XmppService] + [AppDatabase]
// per enabled account, unified chat list.

import 'dart:async';
import 'dart:convert';
import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:logging/logging.dart';
import 'package:moxxmpp/moxxmpp.dart' show ConferenceBookmark, PresenceShow;

import 'package:resonchat/account/account_color.dart';
import 'package:resonchat/account/chat_ref.dart';
import 'package:resonchat/crypto/dual/blind_trust_prefs.dart';
import 'package:resonchat/crypto/dual/dual_track_manager.dart';
import 'package:resonchat/crypto/dual/fingerprint_trust.dart';
import 'package:resonchat/domain/messages_service.dart';
import 'package:resonchat/domain/roster_service.dart';
import 'package:resonchat/net/app_network.dart';
import 'package:resonchat/persistence/account_store.dart';
import 'package:resonchat/persistence/database.dart';
import 'package:resonchat/persistence/omemo2_device_store.dart';
import 'package:resonchat/persistence/omemo_device_store.dart';
import 'package:resonchat/persistence/roster_state.dart';
import 'package:resonchat/platform/android_keepalive.dart';
import 'package:resonchat/xmpp/account_connection_controller.dart';
import 'package:resonchat/xmpp/account_connection_state.dart';
import 'package:resonchat/xmpp/connect_failure.dart';
import 'package:resonchat/xmpp/connection.dart';
import 'package:resonchat/xmpp/connectivity_plus_manager.dart';
import 'package:resonchat/xmpp/conversation_archive.dart';
import 'package:resonchat/xmpp/encryption/b_track_manager.dart';
import 'package:resonchat/xmpp/muc/muc.dart';

/// One chat row in the unified inbox.
class AccountChat {
  const AccountChat({required this.account, required this.chat});

  final StoredAccount account;
  final Chat chat;

  ChatRef get ref => ChatRef(accountId: account.id, jid: chat.jid);

  /// Accent for list chrome (avatar halo), not for contact text.
  Color get accent => accountAccent(account.bareJid);
}

/// One roster contact across accounts.
class AccountContact {
  const AccountContact({required this.account, required this.entry});

  final StoredAccount account;
  final RosterEntry entry;

  ChatRef get ref => ChatRef(accountId: account.id, jid: entry.jid);
  Color get accent => accountAccent(account.bareJid);

  String get displayName =>
      entry.name.trim().isNotEmpty ? entry.name.trim() : entry.jid;
}

/// One MUC bookmark (XEP-0402 / legacy) across accounts.
class AccountBookmark {
  const AccountBookmark({required this.account, required this.bookmark});

  final StoredAccount account;
  final ConferenceBookmark bookmark;

  ChatRef get ref => ChatRef(accountId: account.id, jid: bookmark.jid);
  Color get accent => accountAccent(account.bareJid);
}

/// Live session for one account.
class AccountSession {
  AccountSession({required this.account, required this.db, required this.xmpp})
    : messages = MessagesService(db),
      roster = RosterService(db);

  StoredAccount account;
  final AppDatabase db;
  final MessagesService messages;
  final RosterService roster;
  final XmppService xmpp;
  DualTrackManager? tracks;
  final List<StreamSubscription<Object?>> subs = [];

  Future<void> dispose() async {
    for (final s in subs) {
      await s.cancel();
    }
    subs.clear();
    try {
      await xmpp.disconnect();
    } finally {
      // The database is closed even if the socket teardown failed: a session
      // left holding an open SQLite handle blocks the next spare (and the
      // account looked "off but still there" after a reconnect).
      await db.close();
    }
  }
}

/// Process-wide multi-account manager.
class AccountHub extends ChangeNotifier {
  AccountHub({AccountStore? store}) : _store = store ?? AccountStore() {
    _connectivity = ConnectivityPlusConnectivityManager();
    _controller = AccountConnectionController(
      connectAccount: _controllerConnect,
      disconnectAccount: _controllerDisconnect,
      sendPing: _controllerPing,
      isEnabled: (id) {
        final i = _accounts.indexWhere((a) => a.id == id);
        return i >= 0 && _accounts[i].enabled && _sessions.containsKey(id);
      },
      accountIds: () => _sessions.keys,
      connectFailureState: _controllerFailureState,
      // Fail closed: a plugin error must not look like "network restored".
      checkNetwork: () => _connectivity.hasConnectionStrict(failOpen: false),
      // No Jingle/calls yet — hook returns false; SEE_OTHER_HOST still aggressive.
      hasActiveJingleRtpCall: (_) => false,
      wakeScheduler: AndroidWakeScheduler(),
    );
  }

  final AccountStore _store;
  final _log = Logger('AccountHub');
  final Map<String, AccountSession> _sessions = {};
  List<StoredAccount> _accounts = [];

  late final ConnectivityPlusConnectivityManager _connectivity;
  late final AccountConnectionController _controller;
  StreamSubscription<void>? _connectivityOnlineSub;
  StreamSubscription<void>? _connectivityOfflineSub;
  StreamSubscription<void>? _connectivityChangedSub;

  /// Conversations-style connection scheduler (sole reconnect clock).
  AccountConnectionController get connectionController => _controller;

  final StreamController<void> _sessionChanges =
      StreamController<void>.broadcast();
  final StreamController<void> _chatsTick = StreamController<void>.broadcast();
  final StreamController<void> _rosterTick = StreamController<void>.broadcast();
  final StreamController<void> _bookmarksTick =
      StreamController<void>.broadcast();

  Stream<void> get sessionChanges => _sessionChanges.stream;

  List<StoredAccount> get accounts => List.unmodifiable(_accounts);
  Iterable<AccountSession> get sessions => _sessions.values;
  bool get hasAccounts => _accounts.isNotEmpty;

  /// At least one account may open a session (not OPTION_DISABLED).
  bool get hasEnabledAccounts => _accounts.any((a) => a.enabled);

  AccountSession? session(String accountId) => _sessions[accountId];

  AccountSession? get primarySession {
    for (final a in _accounts) {
      if (!a.enabled) continue;
      final s = _sessions[a.id];
      if (s != null) return s;
    }
    return _sessions.isEmpty ? null : _sessions.values.first;
  }

  AppDatabase? get primaryDbOrNull => primarySession?.db;
  XmppService? get primaryXmppOrNull => primarySession?.xmpp;

  /// Opens per-account databases without connecting.
  ///
  /// Shared SOCKS/locale prefs live in [appPrefs] (opened in [main] before
  /// this). Call [connectAll] only after [AppNetwork.loadFrom] has applied
  /// those prefs.
  Future<void> openSessions() async {
    final loaded = await _store.loadAll();
    // A failed keystore read must not erase an in-memory list mid-session.
    if (loaded.isEmpty &&
        _store.lastLoadError != null &&
        _accounts.isNotEmpty) {
      _log.severe(
        'account load failed (${_store.lastLoadError}); keeping '
        '${_accounts.length} in-memory account(s)',
      );
    } else {
      _accounts = loaded;
    }
    final openedBare = <String>{};
    for (final a in _accounts.where((a) => a.enabled)) {
      // One live session per XMPP address — never open a second SQLite
      // identity if the keystore somehow listed the same bare JID twice.
      if (!openedBare.add(a.bareJid)) {
        _log.severe(
          'skipping duplicate enabled account ${a.bareJid} (id=${a.id}); '
          'fix via AccountStore.upsert / addAndConnect',
        );
        continue;
      }
      try {
        await _ensureSession(a);
      } catch (e, st) {
        _log.severe('failed to open session for ${a.jid}: $e', e, st);
      }
    }
    notifyListeners();
    _sessionChanges.add(null);
  }

  /// Connects every enabled session and runs post-login bootstrap (OMEMO,
  /// roster, MAM). Waits for [appNetwork] so SOCKS is applied first.
  Future<void> connectAll() async {
    await appNetwork.waitUntilReady();
    await _connectivity.start();
    _controller.setNetworkAvailable(await _connectivity.hasConnection());
    _connectivityOnlineSub ??= _connectivity.becameOnline.listen((_) {
      _controller.onConnectivityRestored();
    });
    _connectivityOfflineSub ??= _connectivity.becameOffline.listen((_) {
      _controller.onConnectivityLost();
    });
    // Wi-Fi → cellular: the interface stays "online" but every existing TCP
    // socket is usually gone. Conversations pings on CONNECTIVITY_ACTION, so
    // treat the type change as a connectivity restore for scheduling purposes.
    _connectivityChangedSub ??= _connectivity.networkChanges.listen((_) {
      _controller.onConnectivityRestored();
    });
    _controller.start();
    _syncAndroidKeepAlive();
    for (final a in _accounts.where((a) => a.enabled)) {
      if (!_sessions.containsKey(a.id)) continue;
      _controller.requestConnect(a.id);
    }
  }

  /// Convenience: [openSessions] then [connectAll] (no SOCKS load in between).
  Future<void> start() async {
    await openSessions();
    await connectAll();
  }

  XmppService _buildXmpp(AppDatabase db, String accountId) {
    late final XmppService xmpp;
    final deviceStore = OmemoDeviceStore(
      accountId: accountId,
      secureStorage: const FlutterSecureStorage(),
      loadSecret: () async {
        final v = await db.metaValue('omemo_device_blob');
        return v == null ? null : base64Decode(v);
      },
      saveSecret: (bytes) =>
          db.setMetaValue('omemo_device_blob', base64Encode(bytes)),
      deleteSecret: () => db.deleteMetaValue('omemo_device_blob'),
    );
    final omemo2Store = Omemo2DeviceStore(
      accountId: accountId,
      secureStorage: const FlutterSecureStorage(),
      loadSecret: () async {
        final v = await db.metaValue('omemo2_device_blob');
        return v == null ? null : base64Decode(v);
      },
      saveSecret: (bytes) =>
          db.setMetaValue('omemo2_device_blob', base64Encode(bytes)),
      deleteSecret: () => db.deleteMetaValue('omemo2_device_blob'),
    );
    final fingerprintTrust = FingerprintTrustStore(
      db,
      blindTrustEnabled: loadOmemoBlindTrust,
    );
    final bTrack = BTrackManager(
      tracks: () => xmpp.tracks!,
      pubsubOf: () => xmpp.pubsub,
      accountId: accountId,
      pqIdentity: deviceStore.pqIdentity,
      deviceStore: omemo2Store,
      fingerprintTrust: fingerprintTrust,
    );
    xmpp = XmppService(
      deviceStore: deviceStore,
      bTrack: bTrack,
      fingerprintTrust: fingerprintTrust,
      accountDb: db,
      connectivityManager: _connectivity,
    );
    xmpp.onRoomRoster = (room) =>
        db.saveRoomMembers(room.roomJid, encodeRoomMembers(room.occupants));
    return xmpp;
  }

  Future<AccountSession> _ensureSession(StoredAccount account) async {
    final existing = _sessions[account.id];
    if (existing != null) {
      existing.account = account;
      return existing;
    }
    final db = await openAppDatabase(accountId: account.id);
    final xmpp = _buildXmpp(db, account.id);
    xmpp.restoreRoomMembers(await db.roomMemberBlobs());
    final session = AccountSession(account: account, db: db, xmpp: xmpp);
    session.subs.add(db.watchChats().listen((_) => _chatsTick.add(null)));
    session.subs.add(
      db.watchArchivedChats().listen((_) => _chatsTick.add(null)),
    );
    session.subs.add(db.watchRoster().listen((_) => _rosterTick.add(null)));
    session.subs.add(
      session.xmpp.bookmarksChanges.listen((_) {
        unawaited(_applyBookmarksToDb(session));
      }),
    );
    // TCP drop flips xmpp.state; controller reconnects — keep hub/UI in sync.
    session.subs.add(
      session.xmpp.stateChanges.listen((_) {
        notifyListeners();
        _sessionChanges.add(null);
      }),
    );
    xmpp.onInboundPacket = () => _controller.notifyPacketReceived(account.id);
    xmpp.onStreamLost = (failure) {
      final state = failure == null
          ? AccountConnectionState.offline
          : accountStateFromConnectFailure(failure);
      _controller.onConnectionLost(account.id, state);
      notifyListeners();
      _sessionChanges.add(null);
    };
    // Cold-start: Contacts reads the on-disk snapshot before PEP fetch.
    // (BookmarksManager does not exist until connect — seed happens in
    // bootstrapSession.)
    _bookmarksTick.add(null);
    _sessions[account.id] = session;
    return session;
  }

  Future<bool> _controllerConnect(String accountId) async {
    // AccountConnectionController owns the state transition and retry
    // decision. Keeping this path from writing "connecting"/"online" itself is
    // what makes a late result after a timeout inert.
    return _connectAndBootstrap(accountId, manageControllerState: false);
  }

  AccountConnectionState _controllerFailureState(String accountId) {
    final failure = _sessions[accountId]?.xmpp.lastFailure;
    return failure == null
        ? AccountConnectionState.unreachable
        : accountStateFromConnectFailure(failure);
  }

  Future<void> _controllerDisconnect(String accountId) async {
    final session = _sessions[accountId];
    if (session == null) return;
    try {
      await session.xmpp.disconnect();
    } catch (e) {
      _log.fine('controller disconnect $accountId: $e');
    }
  }

  Future<bool> _controllerPing(String accountId) async {
    final session = _sessions[accountId];
    if (session == null) return false;
    return session.xmpp.sendLivenessPing();
  }

  Future<bool> _connectSession(
    String accountId, {
    bool manageControllerState = true,
  }) async {
    final session = _sessions[accountId];
    if (session == null) return false;
    final a = session.account;
    if (manageControllerState) {
      _controller.setState(accountId, AccountConnectionState.connecting);
    }
    await appNetwork.waitUntilReady();
    // RFC 6121 availability for the initial presence broadcast.
    final showWire = await session.db.ownPresenceShowWire();
    await session.xmpp.setOwnPresence(PresenceShow.parse(showWire));
    final ok = await session.xmpp.connect(
      jid: a.jid,
      password: a.password,
      host: a.hasHost ? a.host : null,
      rosterState: DriftRosterStateManager(session.db),
    );
    if (!ok) {
      _log.warning('connect failed for ${a.jid}: ${session.xmpp.lastFailure}');
      // The controller path classifies through _controllerFailureState after
      // the future returns; direct callers (add account / password change)
      // still need the state and retry clock moved here.
      if (manageControllerState) {
        _controller.onConnectionLost(
          accountId,
          _controllerFailureState(accountId),
          incrementAttempt: true,
        );
      }
      notifyListeners();
      _sessionChanges.add(null);
      return false;
    }
    if (manageControllerState) {
      _controller.setState(accountId, AccountConnectionState.online);
    }
    _wireTracks(session);
    notifyListeners();
    _sessionChanges.add(null);
    _syncAndroidKeepAlive();
    return true;
  }

  Future<bool> _connectAndBootstrap(
    String accountId, {
    bool manageControllerState = true,
  }) async {
    final ok = await _connectSession(
      accountId,
      manageControllerState: manageControllerState,
    );
    if (!ok) return false;
    final session = _sessions[accountId];
    if (session == null) return false;
    // Bootstrap is *not* part of being logged in. It is a roster fetch, two
    // OMEMO bundle publishes, a bookmarks fetch, one MUC join per autojoin
    // room (20 s timeout each) and up to 15 serial MAM pages — all of which
    // used to sit between "authenticated" and the login spinner stopping.
    // Run it behind the session, exactly like the cold-start path
    // ([connectAll]) already does, and report completion on the session
    // ticks the UI already listens to.
    unawaited(_bootstrapInBackground(session));
    return true;
  }

  void _syncAndroidKeepAlive() {
    if (!AndroidKeepAlive.isSupported) return;
    if (hasEnabledAccounts) {
      unawaited(AndroidKeepAlive.start());
    } else {
      unawaited(AndroidKeepAlive.stop());
    }
  }

  /// Runs [bootstrapSession] off the login path and surfaces its completion.
  ///
  /// [bootstrapSession] already swallows and logs its own failures, so this
  /// only has to make sure listeners hear about the finished state.
  Future<void> _bootstrapInBackground(AccountSession session) async {
    final epoch = session.xmpp.connectionEpoch;
    try {
      final ready = await session.xmpp.waitForStreamReady();
      if (epoch != session.xmpp.connectionEpoch) return;
      if (!ready) {
        _log.fine(
          'stream-ready bundle timed out for ${session.account.jid}; '
          'bootstrapping anyway',
        );
      }
      await bootstrapSession(session);
    } finally {
      if (epoch == session.xmpp.connectionEpoch) {
        notifyListeners();
        _sessionChanges.add(null);
      }
    }
  }

  /// Roster / OMEMO / bookmarks / MUC rejoin / MAM catch-up after a successful login.
  ///
  /// Cold start used to skip this (only the login page ran it), leaving
  /// sessions "connected" without an OMEMO device — encrypted sends fail.
  Future<void> bootstrapSession(AccountSession session) async {
    final xmpp = session.xmpp;
    final db = session.db;
    final label = session.account.jid;
    try {
      // Conversations `processResumed`: SM resume keeps the session live —
      // no BindProcessor (roster/bookmarks/presence/OMEMO republish/MUC).
      // Still run incremental MAM; unacked stanzas are already resent by SM.
      final resumed = xmpp.lastStreamResumed;
      if (!resumed) {
        final items = await xmpp.requestRoster();
        final knownRoomJids = await db.groupChatJids();
        for (final item in items) {
          // Never materialise a MUC as a 1:1 chat row from the roster.
          if (knownRoomJids.contains(item.jid)) {
            await xmpp.removeFromRosterIfPresent(item.jid);
            continue;
          }
          await db.upsertChat(item.jid, title: item.name ?? item.jid);
        }
        // Roster upsert must not move chats to "now"; realign from messages
        // (and repair rows stamped with login time by older builds).
        await db.syncChatLastActivity();
        await xmpp.ensureOmemoDevice();
        await xmpp.replenishPrekeys();
        await xmpp.initialiseBTrack();
        // XEP-0402 / legacy bookmarks → local group rows, then rejoin autojoin.
        // Seed from disk so the UI is non-empty and legacy rewrites see the
        // full set if the fetch is slow or fails.
        xmpp.seedBookmarks(await session.roster.loadConferenceBookmarks());
        await xmpp.fetchBookmarks();
        await _applyBookmarksToDb(session);
        final rooms = await db.groupChatsForJoin();
        await xmpp.rejoinGroupChats([
          for (final c in rooms) (roomJid: c.jid, nick: c.mucNick),
        ]);
      } else {
        _log.info('SM resumed for $label; skipping bind bootstrap');
      }
      final afterId = await db.metaValue(XmppService.mamCatchupIdKey);
      final startRaw = await db.metaValue(XmppService.mamCatchupTsKey);
      final metaTs = startRaw != null ? DateTime.tryParse(startRaw) : null;
      final dbTs = await db.latestMessageTimestamp();
      // Always pass the anchor so a day-window catch-up can drop a cursor
      // that is older than the threshold. Private rooms use that same window.
      final DateTime? start;
      if (metaTs != null && dbTs != null) {
        start = metaTs.isAfter(dbTs) ? metaTs : dbTs;
      } else {
        start = metaTs ?? dbTs;
      }
      await xmpp.catchUpHistory(
        afterId: afterId,
        start: start,
        saveCursor: (id, ts) async {
          if (id != null && id.isNotEmpty) {
            await db.setMetaValue(XmppService.mamCatchupIdKey, id);
          }
          if (ts != null) {
            await db.setMetaValue(
              XmppService.mamCatchupTsKey,
              ts.toUtc().toIso8601String(),
            );
          }
        },
      );
    } catch (e, st) {
      _log.severe('bootstrap failed for $label: $e', e, st);
    }
  }

  void _wireTracks(AccountSession session) {
    final xmpp = session.xmpp;
    final moxxOmemo = xmpp.moxxOmemo;
    final pubsub = xmpp.pubsub;
    if (moxxOmemo == null || pubsub == null) return;
    final tracks = DualTrackManager(aTrack: moxxOmemo, pubsubOf: () => pubsub);
    xmpp.tracks = tracks;
    session.tracks = tracks;
    tracks.omemoDeviceMemory = PublishedDeviceMemory(
      load: () => session.db.publishedOmemoDeviceIds(),
      save: (ids) => session.db.savePublishedOmemoDeviceIds(ids),
    );
    tracks.pqDeviceMemory = PublishedDeviceMemory(
      load: () => session.db.publishedPqDeviceIds(),
      save: (ids) => session.db.savePublishedPqDeviceIds(ids),
    );
  }

  /// Last failure from [addAndConnect], if any. The UI renders it in its own
  /// (localized) words — see `connectFailureLabel`.
  XmppConnectFailure? lastConnectFailure;

  /// Add (or update) an account and connect it.
  ///
  /// Credentials are written to the account store only after a successful
  /// connect. A failed attempt must not leave a never-logged-in row in the
  /// list (tapping it would only fail again).
  Future<bool> addAndConnect({
    required String jid,
    required String password,
    String? host,
  }) async {
    lastConnectFailure = null;
    final bare = (jid.contains('/') ? jid.split('/').first : jid).toLowerCase();
    // Prefer keystore as source of truth so a second "add" of the same JID
    // reuses the existing local id (and its DB), never mints a parallel one.
    StoredAccount? existing;
    for (final a in _accounts) {
      if (a.bareJid == bare) {
        existing = a;
        break;
      }
    }
    if (existing == null) {
      final stored = await _store.loadAll();
      if (_store.lastLoadError == null) {
        for (final a in stored) {
          if (a.bareJid == bare) {
            existing = a;
            break;
          }
        }
      }
    }
    final account = StoredAccount(
      id: existing?.id ?? newAccountId(),
      jid: jid.trim(),
      password: password,
      host: (host == null || host.trim().isEmpty) ? null : host.trim(),
      displayName: existing?.displayName ?? '',
      enabled: existing?.enabled ?? true,
    );
    // If we already have a live session under another id for this bare JID,
    // refuse to open a second one — update that session instead.
    for (final s in _sessions.values) {
      if (s.account.bareJid == bare && s.account.id != account.id) {
        _log.warning(
          'addAndConnect: session already open for $bare as ${s.account.id}; '
          'reusing that identity',
        );
        final reused = account.copyWith(id: s.account.id);
        s.account = reused;
        final okReuse = await _connectAndBootstrap(reused.id);
        if (okReuse) {
          await _store.upsert(reused);
          _accounts = await _store.loadAll();
          notifyListeners();
          _sessionChanges.add(null);
          _chatsTick.add(null);
        } else {
          lastConnectFailure = s.xmpp.lastFailure;
          notifyListeners();
          _sessionChanges.add(null);
        }
        return okReuse;
      }
    }
    final session = await _ensureSession(account);
    final ok = await _connectAndBootstrap(session.account.id);
    if (!ok) {
      lastConnectFailure = session.xmpp.lastFailure;
      if (existing == null) {
        // Brand-new account: drop the ephemeral session; nothing to persist.
        _controller.removeAccount(account.id);
        _sessions.remove(account.id);
        await session.dispose();
      } else {
        // Keep the previously stored credentials in memory.
        session.account = existing;
      }
      notifyListeners();
      _sessionChanges.add(null);
      return false;
    }
    await _store.upsert(account);
    _accounts = await _store.loadAll();
    notifyListeners();
    _sessionChanges.add(null);
    _chatsTick.add(null);
    return true;
  }

  Future<void> setEnabled(String accountId, bool enabled) async {
    final i = _accounts.indexWhere((a) => a.id == accountId);
    if (i < 0) return;
    final updated = _accounts[i].copyWith(enabled: enabled);
    try {
      await _store.upsert(updated);
      final loaded = await _store.loadAll();
      if (loaded.isEmpty && _store.lastLoadError != null) {
        _accounts = [..._accounts]..[i] = updated;
      } else {
        _accounts = loaded;
      }
    } catch (e, st) {
      _log.severe('setEnabled persist failed for $accountId: $e', e, st);
      // Still apply in memory so the switch and session match the UI.
      _accounts = [..._accounts]..[i] = updated;
    }
    if (!enabled) {
      _controller.removeAccount(accountId);
      final s = _sessions.remove(accountId);
      await s?.dispose();
      _syncAndroidKeepAlive();
    } else {
      await _ensureSession(updated);
      _controller.requestConnect(accountId);
      _syncAndroidKeepAlive();
    }
    notifyListeners();
    _sessionChanges.add(null);
    _chatsTick.add(null);
  }

  /// Persist local display name and publish XEP-0172 nick when online.
  Future<bool> setDisplayName(String accountId, String displayName) async {
    final i = _accounts.indexWhere((a) => a.id == accountId);
    if (i < 0) return false;
    final updated = _accounts[i].copyWith(displayName: displayName.trim());
    await _store.upsert(updated);
    _accounts = await _store.loadAll();
    final session = _sessions[accountId];
    if (session != null) {
      session.account = updated;
      final ok = await session.xmpp.publishDisplayName(updated.displayName);
      notifyListeners();
      return ok;
    }
    notifyListeners();
    return true;
  }

  /// Changes the password on the server, stores it, and reconnects with it.
  ///
  /// A live session keeps the old password inside its connection settings, so
  /// the next automatic reconnect would be rejected. [connect] builds a new
  /// session from [StoredAccount.password].
  Future<bool> changeAccountPassword(
    String accountId,
    String newPassword,
  ) async {
    final session = _sessions[accountId];
    if (session == null) return false;
    if (session.xmpp.state != XmppConnectionState.connected) return false;
    final ok = await session.xmpp.changePassword(newPassword);
    if (!ok) return false;
    final i = _accounts.indexWhere((a) => a.id == accountId);
    if (i < 0) return false;
    final updated = _accounts[i].copyWith(password: newPassword);
    await _store.upsert(updated);
    _accounts = await _store.loadAll();
    final stored = _accounts.where((a) => a.id == accountId).firstOrNull;
    session.account = stored ?? updated;
    notifyListeners();
    await _connectSession(accountId);
    return true;
  }

  /// Removes the account from this device.
  ///
  /// When [unregisterOnServer] is set, the server must accept XEP-0077
  /// `<remove/>` first. A refusal leaves the local account in place.
  Future<bool> removeAccount(
    String accountId, {
    bool unregisterOnServer = false,
  }) async {
    if (unregisterOnServer) {
      final session = _sessions[accountId];
      if (session == null ||
          session.xmpp.state != XmppConnectionState.connected) {
        return false;
      }
      final ok = await session.xmpp.unregisterAccount();
      if (!ok) return false;
    }
    final s = _sessions.remove(accountId);
    _controller.removeAccount(accountId);
    await s?.dispose();
    await _store.remove(accountId);
    _accounts = await _store.loadAll();
    _syncAndroidKeepAlive();
    notifyListeners();
    _sessionChanges.add(null);
    _chatsTick.add(null);
    return true;
  }

  /// Sessions that may contribute to the unified inbox (enabled accounts only).
  ///
  /// Copied before any `await` so a concurrent [setEnabled] cannot leave a
  /// disposed session in the iteration, and disabled accounts never leak rows.
  List<AccountSession> _enabledSessionsSnapshot() {
    final enabledIds = {
      for (final a in _accounts)
        if (a.enabled) a.id,
    };
    return [
      for (final s in _sessions.values)
        if (enabledIds.contains(s.account.id)) s,
    ];
  }

  StoredAccount _accountForSession(AccountSession s) {
    for (final a in _accounts) {
      if (a.id == s.account.id) return a;
    }
    return s.account;
  }

  Future<List<AccountChat>> snapshotChats({bool archivedOnly = false}) async {
    final sessions = _enabledSessionsSnapshot();
    final rows = <AccountChat>[];
    final seen = <String>{};
    for (final s in sessions) {
      final account = _accountForSession(s);
      if (!account.enabled) continue;
      final list = archivedOnly
          ? await s.db.watchArchivedChats().first
          : await s.db.watchChats().first;
      for (final c in list) {
        final key = ChatRef(accountId: account.id, jid: c.jid).key;
        if (!seen.add(key)) continue;
        rows.add(AccountChat(account: account, chat: c));
      }
    }
    rows.sort((a, b) {
      final ap = a.chat.pinned ? 1 : 0;
      final bp = b.chat.pinned ? 1 : 0;
      if (ap != bp) return bp.compareTo(ap);
      return b.chat.lastActivity.compareTo(a.chat.lastActivity);
    });
    return rows;
  }

  Stream<List<AccountChat>> watchMergedChats({bool archivedOnly = false}) {
    late final StreamController<List<AccountChat>> controller;
    StreamSubscription<void>? tickSub;
    StreamSubscription<void>? sessionSub;
    // Drop superseded async snapshots: disable/enable races used to push an
    // older list (still containing the disabled account) after a newer one.
    var emitGen = 0;

    Future<void> emit() async {
      final token = ++emitGen;
      final rows = await snapshotChats(archivedOnly: archivedOnly);
      if (token != emitGen || controller.isClosed) return;
      controller.add(rows);
    }

    controller = StreamController<List<AccountChat>>(
      onListen: () {
        unawaited(emit());
        tickSub = _chatsTick.stream.listen((_) => unawaited(emit()));
        sessionSub = _sessionChanges.stream.listen((_) => unawaited(emit()));
      },
      onCancel: () async {
        emitGen++;
        await tickSub?.cancel();
        await sessionSub?.cancel();
      },
    );
    return controller.stream;
  }

  Future<List<AccountContact>> snapshotRoster() async {
    final sessions = _enabledSessionsSnapshot();
    final rows = <AccountContact>[];
    final seen = <String>{};
    for (final s in sessions) {
      final account = _accountForSession(s);
      if (!account.enabled) continue;
      // Rooms are bookmarks / MODE_MULTI chats, never contacts. A public
      // channel that was wrongly rostered (or joined after a contact add)
      // must not appear here — Conversations keeps conferences off the
      // contact list entirely.
      final rooms = await s.db.groupChatJids();
      final list = await s.db.allRosterEntries();
      for (final e in list) {
        if (rooms.contains(e.jid)) continue;
        final key = ChatRef(accountId: account.id, jid: e.jid).key;
        if (!seen.add(key)) continue;
        rows.add(AccountContact(account: account, entry: e));
      }
    }
    rows.sort(
      (a, b) =>
          a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()),
    );
    return rows;
  }

  Stream<List<AccountContact>> watchMergedRoster() {
    late final StreamController<List<AccountContact>> controller;
    StreamSubscription<void>? tickSub;
    StreamSubscription<void>? chatsSub;
    StreamSubscription<void>? sessionSub;
    var emitGen = 0;

    Future<void> emit() async {
      final token = ++emitGen;
      final rows = await snapshotRoster();
      if (token != emitGen || controller.isClosed) return;
      controller.add(rows);
    }

    controller = StreamController<List<AccountContact>>(
      onListen: () {
        unawaited(emit());
        tickSub = _rosterTick.stream.listen((_) => unawaited(emit()));
        // isGroup flips (join channel) must hide that JID from Contacts even
        // before a roster push arrives.
        chatsSub = _chatsTick.stream.listen((_) => unawaited(emit()));
        sessionSub = _sessionChanges.stream.listen((_) => unawaited(emit()));
      },
      onCancel: () async {
        emitGen++;
        await tickSub?.cancel();
        await chatsSub?.cancel();
        await sessionSub?.cancel();
      },
    );
    return controller.stream;
  }

  Future<List<AccountBookmark>> snapshotBookmarks() async {
    final sessions = _enabledSessionsSnapshot();
    final rows = <AccountBookmark>[];
    final seen = <String>{};
    for (final s in sessions) {
      final account = _accountForSession(s);
      if (!account.enabled) continue;
      // Prefer the live PEP cache when it has been seeded / fetched; otherwise
      // fall back to the on-disk snapshot so Contacts shows a non-zero count
      // before bootstrap finishes.
      var list = s.xmpp.cachedBookmarks;
      if (list.isEmpty) {
        list = await s.roster.loadConferenceBookmarks();
      }
      for (final b in list) {
        final key = ChatRef(accountId: account.id, jid: b.jid).key;
        if (!seen.add(key)) continue;
        rows.add(AccountBookmark(account: account, bookmark: b));
      }
    }
    rows.sort(
      (a, b) => a.bookmark.displayName.toLowerCase().compareTo(
        b.bookmark.displayName.toLowerCase(),
      ),
    );
    return rows;
  }

  Stream<List<AccountBookmark>> watchMergedBookmarks() {
    late final StreamController<List<AccountBookmark>> controller;
    StreamSubscription<void>? tickSub;
    StreamSubscription<void>? sessionSub;
    var emitGen = 0;

    Future<void> emit() async {
      final token = ++emitGen;
      final rows = await snapshotBookmarks();
      if (token != emitGen || controller.isClosed) return;
      controller.add(rows);
    }

    controller = StreamController<List<AccountBookmark>>(
      onListen: () {
        unawaited(emit());
        tickSub = _bookmarksTick.stream.listen((_) => unawaited(emit()));
        sessionSub = _sessionChanges.stream.listen((_) => unawaited(emit()));
      },
      onCancel: () async {
        emitGen++;
        await tickSub?.cancel();
        await sessionSub?.cancel();
      },
    );
    return controller.stream;
  }

  /// Persist bookmark rooms locally so rejoin / UI see them without mixing
  /// into the roster.
  Future<void> _applyBookmarksToDb(AccountSession session) async {
    final db = session.db;
    final bookmarks = session.xmpp.cachedBookmarks;
    // Disk snapshot for cold start (Contacts count before the next PEP fetch).
    await session.roster.saveConferenceBookmarks(bookmarks);
    final fallbackNick = session.account.bareJid.split('@').first;
    for (final b in bookmarks) {
      final nick = (b.nick != null && b.nick!.trim().isNotEmpty)
          ? b.nick!.trim()
          : fallbackNick;
      // autojoin → store nick so [groupChatsForJoin] rejoins; otherwise keep
      // the row but clear nick so connect does not force presence.
      // Only write a title when the bookmark carries a real name — otherwise
      // leave disco-filled / previously-set names alone (localpart fallback
      // would wipe them on every sync).
      final bookmarkName = b.name?.trim();
      // Snapshot before upsert. Conversations only archives when PEP says
      // autoJoin=false *and* the conference is still in the active list
      // (`service.find`). Our stand-in for "active" is a non-empty mucNick
      // (joined / would rejoin). Bookmark stubs with autoJoin already false
      // must not be swept into the archive on every bookmarksChanges — that
      // misfired after we archived one room and the full list re-applied.
      final prior = await db.getChat(b.jid);
      await db.upsertChat(
        b.jid,
        title: (bookmarkName != null && bookmarkName.isNotEmpty)
            ? bookmarkName
            : null,
        isGroup: true,
        mucNick: b.autoJoin ? nick : '',
      );
      await session.xmpp.removeFromRosterIfPresent(b.jid);
      if (!b.autoJoin &&
          prior != null &&
          prior.isGroup &&
          !prior.archived &&
          prior.mucNick.isNotEmpty) {
        final key = ChatRef(accountId: session.account.id, jid: b.jid).key;
        await archiveConversation(key, syncBookmarks: false);
      }
    }
    _bookmarksTick.add(null);
    _chatsTick.add(null);
  }

  /// Call after a live bookmark push so group rows stay aligned.
  Future<void> applyBookmarksFor(String accountId) async {
    final session = _sessions[accountId];
    if (session == null) return;
    await _applyBookmarksToDb(session);
  }

  @override
  void dispose() {
    // Stop the reconnect clock and connectivity listeners before closing the
    // databases: a late connect callback must never touch a disposed session.
    _controller.dispose();
    unawaited(_connectivityOnlineSub?.cancel());
    unawaited(_connectivityOfflineSub?.cancel());
    unawaited(_connectivityChangedSub?.cancel());
    _connectivityOnlineSub = null;
    _connectivityOfflineSub = null;
    _connectivityChangedSub = null;
    _connectivity.dispose();
    for (final s in _sessions.values) {
      unawaited(s.dispose());
    }
    _sessions.clear();
    unawaited(_sessionChanges.close());
    unawaited(_chatsTick.close());
    unawaited(_rosterTick.close());
    unawaited(_bookmarksTick.close());
    super.dispose();
  }
}

AccountHub? _hubSingleton;

AccountHub get accountHub {
  final h = _hubSingleton;
  if (h == null) throw StateError('AccountHub not started');
  return h;
}

void installAccountHub(AccountHub hub) => _hubSingleton = hub;
