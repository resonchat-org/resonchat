// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Web (and any js_interop target): no reliable system-mic mute API — skip.

/// Always unknown on web; caller treats [null] as "do not block recording".
Future<bool?> isDefaultMicMuted() async => null;
