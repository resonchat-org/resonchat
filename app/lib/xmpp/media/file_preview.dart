// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Gajim `preview_max_file_size`: one cap for automatic preview downloads of
// images and other files. 0 turns automatic download off.

import 'package:resonchat/persistence/prefs_database.dart';

const previewMaxFileSizeKey = 'pref_preview_max_file_size';

/// Gajim default: 10 MiB.
const kDefaultPreviewMaxFileSize = 10485760;

/// Gajim File Size Limit choices, in bytes. 0 = no automatic preview.
const previewMaxFileSizeChoices = <int>[
  0,
  262144,
  524288,
  1048576,
  5242880,
  10485760,
  26214400,
];

Future<int> loadPreviewMaxFileSize([PrefsDatabase? prefs]) async {
  final raw = await (prefs ?? appPrefs).getString(previewMaxFileSizeKey);
  final parsed = int.tryParse(raw ?? '');
  if (parsed == null || !previewMaxFileSizeChoices.contains(parsed)) {
    return kDefaultPreviewMaxFileSize;
  }
  return parsed;
}

Future<void> savePreviewMaxFileSize(int bytes, [PrefsDatabase? prefs]) {
  final stored = previewMaxFileSizeChoices.contains(bytes)
      ? bytes
      : kDefaultPreviewMaxFileSize;
  return (prefs ?? appPrefs).setString(previewMaxFileSizeKey, '$stored');
}

/// Whether to start a preview download without a tap.
///
/// Own files always qualify (Gajim `_from_us`). A group chat qualifies only
/// when disco already says it is members-only; a 1:1 chat always qualifies.
bool shouldAutoDownload({
  required int maxBytes,
  required bool incoming,
  required bool isGroup,
  required bool membersOnly,
}) {
  if (maxBytes <= 0) return false;
  if (!incoming) return true;
  if (isGroup && !membersOnly) return false;
  return true;
}
