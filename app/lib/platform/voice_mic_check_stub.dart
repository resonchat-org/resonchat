// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Web: no reliable system-mic mute API — skip.

import 'linux_cli_types.dart';

export 'linux_cli_types.dart' show MicMuteProbe;

Future<MicMuteProbe> probeDefaultMicMute() async => const MicMuteProbe();

Future<bool?> isDefaultMicMuted() async => null;
