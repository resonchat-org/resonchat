// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Multi-account credentials (Conversations `accounts` table), held in the
// platform keystore. Passwords never go into SQLite.

import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// One local XMPP account.
class StoredAccount {
  const StoredAccount({
    required this.id,
    required this.jid,
    required this.password,
    this.host,
    this.enabled = true,
  });

  /// Stable id (Conversations account UUID). Used in the account DB filename.
  final String id;
  final String jid;
  final String password;

  /// Optional host override. Null means discover from the JID.
  final String? host;

  /// When false, the hub does not open a session (Conversations OPTION_DISABLED).
  final bool enabled;

  bool get hasHost => host != null && host!.isNotEmpty;

  String get bareJid {
    final at = jid.indexOf('/');
    return (at < 0 ? jid : jid.substring(0, at)).toLowerCase();
  }

  StoredAccount copyWith({
    String? id,
    String? jid,
    String? password,
    String? host,
    bool? enabled,
    bool clearHost = false,
  }) => StoredAccount(
    id: id ?? this.id,
    jid: jid ?? this.jid,
    password: password ?? this.password,
    host: clearHost ? null : (host ?? this.host),
    enabled: enabled ?? this.enabled,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'jid': jid,
    'password': password,
    if (hasHost) 'host': host,
    'enabled': enabled,
  };

  factory StoredAccount.fromJson(Map<String, dynamic> json) => StoredAccount(
    id: json['id'] as String,
    jid: json['jid'] as String,
    password: json['password'] as String,
    host: json['host'] as String?,
    enabled: json['enabled'] as bool? ?? true,
  );
}

/// Reads and writes the account list in the platform keystore.
class AccountStore {
  AccountStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  static const _listKey = 'resonchat.accounts.v1';

  // Legacy single-account keys (migrated on first [loadAll]).
  static const _jidKey = 'resonchat.account.jid';
  static const _passwordKey = 'resonchat.account.password';
  static const _hostKey = 'resonchat.account.host';

  Future<List<StoredAccount>> loadAll() async {
    try {
      final raw = await _storage.read(key: _listKey);
      if (raw != null && raw.isNotEmpty) {
        final list = jsonDecode(raw) as List<dynamic>;
        return [
          for (final e in list)
            StoredAccount.fromJson(Map<String, dynamic>.from(e as Map)),
        ];
      }
      return await _migrateLegacy();
    } catch (_) {
      // Must be growable: [upsert] mutates the returned list.
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

  Future<void> saveAll(List<StoredAccount> accounts) async {
    await _storage.write(
      key: _listKey,
      value: jsonEncode([for (final a in accounts) a.toJson()]),
    );
  }

  Future<void> upsert(StoredAccount account) async {
    final all = await loadAll();
    final i = all.indexWhere((a) => a.id == account.id);
    if (i < 0) {
      // Same bare JID → replace credentials (re-login).
      final j = all.indexWhere((a) => a.bareJid == account.bareJid);
      if (j >= 0) {
        all[j] = account.copyWith(id: all[j].id);
      } else {
        all.add(account);
      }
    } else {
      all[i] = account;
    }
    await saveAll(all);
  }

  Future<void> remove(String id) async {
    final all = await loadAll();
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
