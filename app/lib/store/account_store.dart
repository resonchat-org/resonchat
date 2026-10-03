// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The account this device last logged in with, and its password.
//
// ## Why the password is stored at all
//
// Not for convenience. Because the alternative is what this app was doing: a
// cold start, or any dropped socket, lands on an empty login form and asks the
// user to retype a password they cannot read from the screen. Every reconnect
// became a manual task, which means a client that cannot be left running is a
// client that is not actually a client.
//
// ## Why it is acceptable
//
// XMPP has no token: the credential *is* the password, and every message client
// that keeps you logged in keeps it. So the question is not "may it be stored"
// but "where", and the answer is the platform keystore via
// `FlutterSecureStorage` — the same store already used for the database
// passphrase and the OMEMO keys. Nothing here is written to the database, to
// preferences, or to a file, so it does not travel with a backup of anything
// else.
//
// ## What is deliberately absent
//
// No "remember me" flag and no account switcher. One account is what this build
// supports, and a flag that can be off while the password is still on disk
// would be a lie in one direction or the other.

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// A stored account.
class StoredAccount {
  const StoredAccount({
    required this.jid,
    required this.password,
    this.host,
  });

  final String jid;
  final String password;

  /// Optional host override. Null means "discover the server from the JID".
  final String? host;

  bool get hasHost => host != null && host!.isNotEmpty;
}

/// Reads and writes [StoredAccount] in the platform keystore.
class AccountStore {
  AccountStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _jidKey = 'resonchat.account.jid';
  static const _passwordKey = 'resonchat.account.password';
  static const _hostKey = 'resonchat.account.host';

  /// The stored account, or null when there is none or it is incomplete.
  ///
  /// Incomplete rather than partial: an account with no password cannot be
  /// logged in with, and returning a half-built record would push the "which
  /// field is missing" question into every caller instead of answering it once
  /// here. A store that lost its password — a keystore reset, a restore onto a
  /// new device — therefore reads as *no account*, which is exactly what it is.
  Future<StoredAccount?> load() async {
    try {
      final jid = await _storage.read(key: _jidKey);
      final password = await _storage.read(key: _passwordKey);
      if (jid == null || jid.isEmpty) return null;
      if (password == null || password.isEmpty) return null;
      final host = await _storage.read(key: _hostKey);
      return StoredAccount(
        jid: jid,
        password: password,
        host: (host == null || host.isEmpty) ? null : host,
      );
    } catch (_) {
      // A keystore that cannot be read is indistinguishable, for this purpose,
      // from one holding nothing — and neither is a reason to refuse to start.
      // The user is asked to log in, which is the same thing that would have
      // happened, minus a crash on the launch path.
      return null;
    }
  }

  /// Stores [account], replacing whatever was there.
  Future<void> save(StoredAccount account) async {
    await _storage.write(key: _jidKey, value: account.jid);
    await _storage.write(key: _passwordKey, value: account.password);
    if (account.hasHost) {
      await _storage.write(key: _hostKey, value: account.host);
    } else {
      // Cleared rather than left stale: a host from a previous account would
      // send this account's traffic to a server it does not belong to, and the
      // failure would look like a network problem rather than a stored value.
      await _storage.delete(key: _hostKey);
    }
  }

  /// Forgets the account. Used on logout and on an authentication failure.
  Future<void> clear() async {
    await _storage.delete(key: _jidKey);
    await _storage.delete(key: _passwordKey);
    await _storage.delete(key: _hostKey);
  }
}