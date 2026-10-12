// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Default capture endpoint soft-mute / zero-volume probe (WASAPI).

#ifndef RUNNER_AUDIO_MUTE_H_
#define RUNNER_AUDIO_MUTE_H_

#include <optional>

/// Soft mute on the default capture device, matching Linux/Android probes:
/// muted, or master level at 0%. `nullopt` when the endpoint cannot be read.
std::optional<bool> QueryDefaultCaptureMuted();

#endif  // RUNNER_AUDIO_MUTE_H_
