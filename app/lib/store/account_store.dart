// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Multi-account credentials (Conversations `accounts` table), held in the
// platform keystore. Passwords never go into SQLite.

import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:logging/logging.dart';

/// One local XMPP account.
class StoredAccount {
  const StoredAccount({
    required this.id,
    required this.jid,
    required this.password,
    this.host,
    this.enabled = true,
    this.displayName = '',
  });

  /// Stable id (Conversations account UUID). Used in the account DB filename.
  final String id;
  final String jid;
  final String password;

  /// Optional host override. Null means discover from the JID.
  final String? host;

  /// When false, the hub does not open a session (Conversations OPTION_DISABLED).
  final bool enabled;

  /// XEP-0172 nick published for this account (local cache).
  final String displayName;

  bool get hasHost => host != null && host!.isNotEmpty;

  String get bareJid {
    final at = jid.indexOf('/');
    return (at < 0 ? jid : jid.substring(0, at)).toLowerCase();
  }

  /// UI title: display name, else localpart.
  String get label {
    final nick = displayName.trim();
    if (nick.isNotEmpty) return nick;
    final bare = bareJid;
    final at = bare.indexOf('@');
    return at > 0 ? bare.substring(0, at) : bare;
  }

  StoredAccount copyWith({
    String? id,
    String? jid,
    String? password,
    String? host,
    bool? enabled,
    String? displayName,
    bool clearHost = false,
  }) => StoredAccount(
    id: id ?? this.id,
    jid: jid ?? this.jid,
    password: password ?? this.password,
    host: clearHost ? null : (host ?? this.host),
    enabled: enabled ?? this.enabled,
    displayName: displayName ?? this.displayName,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'jid': jid,
    'password': password,
    if (hasHost) 'host': host,
    'enabled': enabled,
    if (displayName.trim().isNotEmpty) 'displayName': displayName.trim(),
  };

  factory StoredAccount.fromJson(Map<String, dynamic> json) => StoredAccount(
    id: json['id'] as String,
    jid: json['jid'] as String,
    password: json['password'] as String,
    host: json['host'] as String?,
    enabled: json['enabled'] as bool? ?? true,
    displayName: (json['displayName'] as String?)?.trim() ?? '',
  );
}

/// Reads and writes the account list in the platform keystore.
class AccountStore {
  AccountStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  final _log = Logger('AccountStore');
  static const _listKey = 'resonchat.accounts.v1';

  // Legacy single-account keys (migrated on first [loadAll]).
  static const _jidKey = 'resonchat.account.jid';
  static const _passwordKey = 'resonchat.account.password';
  static const _hostKey = 'resonchat.account.host';

  /// Last [loadAll] failure. Callers must not [saveAll] an empty list over a
  /// failed read — that permanently wipes credentials (clear-cache cannot
  /// recover FlutterSecureStorage).
  Object? lastLoadError;

  Future<List<StoredAccount>> loadAll() async {
    lastLoadError = null;
    try {
      final raw = await _storage.read(key: _listKey);
      if (raw != null && raw.isNotEmpty) {
        final list = jsonDecode(raw) as List<dynamic>;
        // Skip corrupt entries rather than discarding the whole list.
        // Uniqueness by bare JID is enforced on write ([saveAll] / [upsert]),
        // not by silently deleting rows on read.
        final out = <StoredAccount>[];
        for (final e in list) {
          try {
            out.add(
              StoredAccount.fromJson(Map<String, dynamic>.from(e as Map)),
            );
          } catch (err, st) {
            _log.warning('skipping corrupt account entry: $err', err, st);
          }
        }
        return out;
      }
      return await _migrateLegacy();
    } catch (e, st) {
      lastLoadError = e;
      _log.severe('loadAll failed — not treating as empty', e, st);
      // Must be growable for callers that mutate; empty + [lastLoadError] means
      // "unknown", not "user has no accounts".
      return <StoredAccount>[];
    }
  }

  Future<List<StoredAccount>> _migrateLegacy() async {
    final jid = await _storage.read(key: _jidKey);
    final password = await _storage.read(key: _passwordKey);
    if (jid == null || jid.isEmpty || password == null || password.isEmpty) {
      // Must be growable: [upsert] mutates the returned list.
      return <StoredAccount>[];
    }
    final host = await _storage.read(key: _hostKey);
    final account = StoredAccount(
      id: newAccountId(),
      jid: jid,
      password: password,
      host: (host == null || host.isEmpty) ? null : host,
    );
    await saveAll([account]);
    await _storage.delete(key: _jidKey);
    await _storage.delete(key: _passwordKey);
    await _storage.delete(key: _hostKey);
    return [account];
  }

  /// Persists [accounts]. At most one row per bare JID and per id — the store
  /// invariant. Callers that "add" must go through [upsert] / [addAndConnect]
  /// so a second login to the same JID updates credentials instead of forking
  /// a second SQLite identity.
  Future<void> saveAll(List<StoredAccount> accounts) async {
    await _storage.write(
      key: _listKey,
      value: jsonEncode([
        for (final a in _enforceUniqueAccounts(accounts)) a.toJson(),
      ]),
    );
  }

  /// Insert or update one account. Same bare JID always collapses onto the
  /// existing row's [StoredAccount.id] (never a second local identity).
  Future<void> upsert(StoredAccount account) async {
    final all = await loadAll();
    if (lastLoadError != null && all.isEmpty) {
      // Refuse to overwrite keystore with a single row after a failed read.
      throw StateError(
        'AccountStore.upsert: loadAll failed ($lastLoadError); not saving',
      );
    }

    final byId = all.indexWhere((a) => a.id == account.id);
    final byJid = all.indexWhere((a) => a.bareJid == account.bareJid);

    if (byId >= 0 && byJid >= 0 && byId != byJid) {
      // Same credentials claimed under two rows — keep [account.id], drop the
      // other bare-JID owner so we never fork a second SQLite file.
      all.removeAt(byJid);
      final idx = all.indexWhere((a) => a.id == account.id);
      if (idx >= 0) {
        all[idx] = account;
      } else {
        all.add(account);
      }
    } else if (byId >= 0) {
      all[byId] = account;
    } else if (byJid >= 0) {
      // Re-login / "add" of an address we already have: reuse that id.
      all[byJid] = account.copyWith(id: all[byJid].id);
    } else {
      all.add(account);
    }
    await saveAll(all);
  }

  /// Write-side gate: at most one row per id and per bare JID (first wins).
  List<StoredAccount> _enforceUniqueAccounts(List<StoredAccount> accounts) {
    final byId = <String, StoredAccount>{};
    final bareOwner = <String, String>{}; // bareJid → id
    for (final a in accounts) {
      final bare = a.bareJid;
      final existingId = bareOwner[bare];
      if (existingId != null && existingId != a.id) {
        _log.warning(
          'refusing second local identity for $bare '
          '(keeping id=$existingId, ignored id=${a.id})',
        );
        continue;
      }
      byId[a.id] = a;
      bareOwner[bare] = a.id;
    }
    return byId.values.toList(growable: false);
  }

  Future<void> remove(String id) async {
    final all = await loadAll();
    if (lastLoadError != null && all.isEmpty) {
      throw StateError(
        'AccountStore.remove: loadAll failed ($lastLoadError); not saving',
      );
    }
    all.removeWhere((a) => a.id == id);
    await saveAll(all);
  }

  /// True when no accounts are stored (show first-run login).
  Future<bool> get isEmpty async => (await loadAll()).isEmpty;
}

/// Random account id (Conversations-style UUID string).
String newAccountId() {
  final r = Random.secure();
  String hex(int n) => List.generate(
    n,
    (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  return '${hex(4)}-${hex(2)}-${hex(2)}-${hex(2)}-${hex(6)}';
}
