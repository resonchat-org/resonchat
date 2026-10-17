// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// App lock + disguise gate (Amarok-Hider SecurityUtil / PrivacyCategory).
// Disguise UI is 2048, not a calendar; PIN digits map to the 4×4 board.

import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:hex/hex.dart';

import '../store/prefs_database.dart';

/// Symbols for the 16 board cells, top-left → bottom-right (indices 0–15).
const kAppLockPinSymbols = '0123456789ABCDEF';

/// Whether [raw] is a valid stored PIN (4–16 of [kAppLockPinSymbols]).
bool isValidAppLockPin(String raw) {
  if (raw.length < 4 || raw.length > 16) return false;
  final upper = raw.toUpperCase();
  for (final c in upper.codeUnits) {
    if (!kAppLockPinSymbols.codeUnits.contains(c)) return false;
  }
  return true;
}

String pinSymbolAt(int row, int col) {
  assert(row >= 0 && row < 4 && col >= 0 && col < 4);
  return kAppLockPinSymbols[row * 4 + col];
}

Future<String> hashAppLockPin(String pin) async {
  final digest = await Sha256().hash(utf8.encode(pin.toUpperCase()));
  return HEX.encode(digest.bytes);
}

/// Process-wide lock / disguise flags (Amarok `SecurityUtil`).
class AppLock extends ChangeNotifier {
  AppLock._();
  static final AppLock instance = AppLock._();

  bool _enabled = false;
  String? _passwordHash;

  /// True until a correct PIN unlocks this process.
  bool _locked = true;

  /// True until disguise is dismissed (with unlock, for our 2048 flow).
  bool _disguised = true;

  bool get enabled => _enabled;
  bool get hasPassword => _passwordHash != null && _passwordHash!.isNotEmpty;

  /// Show the 2048 disguise instead of the real UI.
  bool get needsDisguise => _enabled && hasPassword && _disguised && _locked;

  Future<void> load(PrefsDatabase prefs) async {
    _enabled = (await prefs.getString('pref_app_lock_enabled')) == '1';
    final hash = await prefs.getString('pref_app_lock_password_hash');
    _passwordHash = (hash == null || hash.isEmpty) ? null : hash;
    // Fresh process always starts locked when a password exists.
    _locked = hasPassword && _enabled;
    _disguised = _locked;
    notifyListeners();
  }

  Future<void> setEnabled(bool enabled) async {
    _enabled = enabled;
    await appPrefs.setString('pref_app_lock_enabled', enabled ? '1' : '0');
    if (!enabled) {
      _locked = false;
      _disguised = false;
    }
    // Enabling does not lock immediately — caller unlocks after set-PIN
    // (Amarok unlock-after-set). Cold start / background re-lock separately.
    notifyListeners();
  }

  Future<void> setPassword(String pin) async {
    final hash = await hashAppLockPin(pin);
    _passwordHash = hash;
    await appPrefs.setString('pref_app_lock_password_hash', hash);
    notifyListeners();
  }

  Future<void> clearPassword() async {
    _passwordHash = null;
    _enabled = false;
    _locked = false;
    _disguised = false;
    await appPrefs.remove('pref_app_lock_password_hash');
    await appPrefs.setString('pref_app_lock_enabled', '0');
    notifyListeners();
  }

  void lockAndDisguise() {
    if (!_enabled || !hasPassword) return;
    _locked = true;
    _disguised = true;
    notifyListeners();
  }

  void unlock() {
    _locked = false;
    _disguised = false;
    notifyListeners();
  }

  Future<bool> tryUnlock(String pin) async {
    final hash = _passwordHash;
    if (hash == null) return false;
    final attempt = await hashAppLockPin(pin);
    if (attempt != hash) return false;
    unlock();
    return true;
  }
}
