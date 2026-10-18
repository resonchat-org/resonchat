// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Web stub for developer log mode. The browser has no Downloads folder a
// `File` could be copied into and no persistent private directory to append
// to, so the mode is reported as unsupported and the settings section that
// would offer it is hidden.

/// No-op counterpart of the native `DevLog`.
class DevLog {
  bool get supported => false;

  bool get running => false;

  Future<void> start() async {}

  Future<void> stop() async {}

  Future<void> setEnabled(bool enabled) async {}

  Future<String?> exportToDownloads() async => null;
}

/// The running instance; a stub on the web.
final devLog = DevLog();
