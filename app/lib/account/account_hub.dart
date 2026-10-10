// Copyright (C) 2026 resonchat contributors.
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

import '../net/app_network.dart';
import '../crypto/omemo/dual_track_manager.dart';
import '../store/account_store.dart';
import '../store/database.dart';
import '../store/omemo_device_store.dart';
import '../store/roster_state.dart';
import '../xmpp/b_track_manager.dart';
import '../xmpp/connection.dart';
import 'account_color.dart';
import 'chat_ref.dart';

/// One chat row in the unified inbox.
class AccountChat {
  const AccountChat({required this.account, required this.chat});

  final StoredAccount account;
  final Chat chat;

  ChatRef get ref => ChatRef(accountId: account.id, jid: chat.jid);

  /// Accent for list chrome (stripe / avatar ring), not for contact text.
  Color get accent => accountAccent(account.bareJid);
}

/// Live session for one account.
class AccountSession {
  AccountSession({required this.account, required this.db, required this.xmpp});

  StoredAccount account;
  final AppDatabase db;
  final XmppService xmpp;
  DualTrackManager? tracks;
  final List<StreamSubscription<Object?>> subs = [];

  Future<void> dispose() async {
    for (final s in subs) {
      await s.cancel();
    }
    subs.clear();
    await xmpp.disconnect();
    await db.close();
  }
}

/// Process-wide multi-account manager.
class AccountHub extends ChangeNotifier {
  AccountHub({AccountStore? store}) : _store = store ?? AccountStore();

  final AccountStore _store;
  final _log = Logger('AccountHub');
  final Map<String, AccountSession> _sessions = {};
  List<StoredAccount> _accounts = [];

  final StreamController<void> _sessionChanges =
      StreamController<void>.broadcast();
  final StreamController<void> _chatsTick = StreamController<void>.broadcast();

  Stream<void> get sessionChanges => _sessionChanges.stream;

  List<StoredAccount> get accounts => List.unmodifiable(_accounts);
  Iterable<AccountSession> get sessions => _sessions.values;
  bool get hasAccounts => _accounts.isNotEmpty;

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
    _accounts = await _store.loadAll();
    for (final a in _accounts.where((a) => a.enabled)) {
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
    for (final a in _accounts.where((a) => a.enabled)) {
      if (!_sessions.containsKey(a.id)) continue;
      unawaited(_connectAndBootstrap(a.id));
    }
  }

  /// Convenience: [openSessions] then [connectAll] (no SOCKS load in between).
  Future<void> start() async {
    await openSessions();
    await connectAll();
  }

  XmppService _buildXmpp(AppDatabase db) {
    late final XmppService xmpp;
    final bTrack = BTrackManager(
      tracks: () => xmpp.tracks!,
      pubsubOf: () => xmpp.pubsub,
    );
    xmpp = XmppService(
      deviceStore: OmemoDeviceStore(
        secureStorage: const FlutterSecureStorage(),
        loadSecret: () async {
          final v = await db.metaValue('omemo_device_blob');
          return v == null ? null : base64Decode(v);
        },
        saveSecret: (bytes) =>
            db.setMetaValue('omemo_device_blob', base64Encode(bytes)),
        deleteSecret: () => db.deleteMetaValue('omemo_device_blob'),
      ),
      bTrack: bTrack,
    );
    return xmpp;
  }

  Future<AccountSession> _ensureSession(StoredAccount account) async {
    final existing = _sessions[account.id];
    if (existing != null) {
      existing.account = account;
      return existing;
    }
    final db = await openAppDatabase(accountId: account.id);
    final xmpp = _buildXmpp(db);
    final session = AccountSession(account: account, db: db, xmpp: xmpp);
    session.subs.add(db.watchChats().listen((_) => _chatsTick.add(null)));
    session.subs.add(
      db.watchArchivedChats().listen((_) => _chatsTick.add(null)),
    );
    _sessions[account.id] = session;
    return session;
  }

  Future<bool> _connectSession(String accountId) async {
    final session = _sessions[accountId];
    if (session == null) return false;
    final a = session.account;
    await appNetwork.waitUntilReady();
    final ok = await session.xmpp.connect(
      jid: a.jid,
      password: a.password,
      host: a.hasHost ? a.host : null,
      rosterState: DriftRosterStateManager(session.db),
    );
    if (!ok) {
      _log.warning('connect failed for ${a.jid}: ${session.xmpp.lastError}');
      notifyListeners();
      _sessionChanges.add(null);
      return false;
    }
    _wireTracks(session);
    notifyListeners();
    _sessionChanges.add(null);
    return true;
  }

  Future<bool> _connectAndBootstrap(String accountId) async {
    final ok = await _connectSession(accountId);
    if (!ok) return false;
    final session = _sessions[accountId];
    if (session == null) return false;
    await bootstrapSession(session);
    notifyListeners();
    _sessionChanges.add(null);
    return true;
  }

  /// Roster / OMEMO / MUC rejoin / MAM catch-up after a successful login.
  ///
  /// Cold start used to skip this (only the login page ran it), leaving
  /// sessions "connected" without an OMEMO device — encrypted sends fail.
  Future<void> bootstrapSession(AccountSession session) async {
    final xmpp = session.xmpp;
    final db = session.db;
    final label = session.account.jid;
    try {
      final items = await xmpp.requestRoster();
      for (final item in items) {
        await db.upsertChat(item.jid, title: item.name ?? item.jid);
      }
      // Roster upsert must not move chats to "now"; realign from messages
      // (and repair rows stamped with login time by older builds).
      await db.syncChatLastActivity();
      await xmpp.ensureOmemoDevice();
      await xmpp.replenishPrekeys();
      await xmpp.initialiseBTrack();
      final rooms = await db.groupChatsForJoin();
      await xmpp.rejoinGroupChats([
        for (final c in rooms) (roomJid: c.jid, nick: c.mucNick),
      ]);
      final afterId = await db.metaValue(XmppService.mamCatchupIdKey);
      final startRaw = await db.metaValue(XmppService.mamCatchupTsKey);
      final metaTs = startRaw != null ? DateTime.tryParse(startRaw) : null;
      final dbTs = await db.latestMessageTimestamp();
      DateTime? start;
      if (afterId == null || afterId.isEmpty) {
        if (metaTs != null && dbTs != null) {
          start = metaTs.isAfter(dbTs) ? metaTs : dbTs;
        } else {
          start = metaTs ?? dbTs;
        }
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
    tracks.deviceMemory = PublishedDeviceMemory(
      load: () => session.db.publishedDeviceIds(),
      save: (ids) => session.db.savePublishedDeviceIds(ids),
    );
  }

  /// Last error from [addAndConnect], if any.
  String? lastConnectError;

  /// Add (or update) an account and connect it.
  Future<bool> addAndConnect({
    required String jid,
    required String password,
    String? host,
  }) async {
    lastConnectError = null;
    final bare = (jid.contains('/') ? jid.split('/').first : jid).toLowerCase();
    StoredAccount? existing;
    for (final a in _accounts) {
      if (a.bareJid == bare) {
        existing = a;
        break;
      }
    }
    final account = StoredAccount(
      id: existing?.id ?? newAccountId(),
      jid: jid.trim(),
      password: password,
      host: (host == null || host.trim().isEmpty) ? null : host.trim(),
      displayName: existing?.displayName ?? '',
    );
    await _store.upsert(account);
    _accounts = await _store.loadAll();
    final session = await _ensureSession(account);
    final ok = await _connectAndBootstrap(session.account.id);
    if (!ok) lastConnectError = session.xmpp.lastError;
    notifyListeners();
    _sessionChanges.add(null);
    _chatsTick.add(null);
    return ok;
  }

  Future<void> setEnabled(String accountId, bool enabled) async {
    final i = _accounts.indexWhere((a) => a.id == accountId);
    if (i < 0) return;
    final updated = _accounts[i].copyWith(enabled: enabled);
    await _store.upsert(updated);
    _accounts = await _store.loadAll();
    if (!enabled) {
      final s = _sessions.remove(accountId);
      await s?.dispose();
    } else {
      await _ensureSession(updated);
      unawaited(_connectAndBootstrap(accountId));
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

  Future<void> removeAccount(String accountId) async {
    final s = _sessions.remove(accountId);
    await s?.dispose();
    await _store.remove(accountId);
    _accounts = await _store.loadAll();
    notifyListeners();
    _sessionChanges.add(null);
    _chatsTick.add(null);
  }

  Future<List<AccountChat>> snapshotChats({bool archivedOnly = false}) async {
    final rows = <AccountChat>[];
    for (final s in _sessions.values) {
      final list = archivedOnly
          ? await s.db.watchArchivedChats().first
          : await s.db.watchChats().first;
      for (final c in list) {
        rows.add(AccountChat(account: s.account, chat: c));
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

    Future<void> emit() async {
      final rows = await snapshotChats(archivedOnly: archivedOnly);
      if (!controller.isClosed) controller.add(rows);
    }

    controller = StreamController<List<AccountChat>>(
      onListen: () {
        unawaited(emit());
        tickSub = _chatsTick.stream.listen((_) => unawaited(emit()));
        sessionSub = _sessionChanges.stream.listen((_) => unawaited(emit()));
      },
      onCancel: () async {
        await tickSub?.cancel();
        await sessionSub?.cancel();
      },
    );
    return controller.stream;
  }

  @override
  void dispose() {
    for (final s in _sessions.values) {
      unawaited(s.dispose());
    }
    _sessions.clear();
    unawaited(_sessionChanges.close());
    unawaited(_chatsTick.close());
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
