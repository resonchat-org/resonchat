// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Shared types for Linux host-CLI probes (no dart:io — safe for web stubs).

/// Thrown when a required host CLI is absent. UI shows a SnackBar and continues.
class MissingLinuxCli implements Exception {
  MissingLinuxCli(this.tools);

  final List<String> tools;

  String get toolsJoined => tools.join(', ');

  @override
  String toString() => 'MissingLinuxCli($toolsJoined)';
}

/// Result of a system-mic soft-mute probe.
///
/// [muted] `true` → block recording; `false` → OK; `null` → skip check.
/// Non-empty [missingCli] → SnackBar those names; recording may still start.
class MicMuteProbe {
  const MicMuteProbe({this.muted, this.missingCli = const []});

  final bool? muted;
  final List<String> missingCli;
}
